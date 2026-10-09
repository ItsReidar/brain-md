//
//  GemmaService.swift
//  brain-md
//

import Combine
import CoreImage
import Foundation
import MLXLMCommon
import os

public enum GemmaServiceError: LocalizedError, Equatable {
    case disabled
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .disabled: "On-device AI is turned off. Turn it on in Settings › Local AI & Voice."
        case .emptyInput: "There's nothing to work with yet: the note is empty."
        }
    }
}

/// Runs note tasks against the on-device Gemma 4 model and streams the answer.
/// The model loads on first use and unloads after `idleUnloadDelay` without requests.
public final class GemmaService: ObservableObject {
    public static let shared = GemmaService()

    /// Long enough to keep the model warm across a burst of requests, short enough to give memory back.
    static let idleUnloadDelay: Duration = .seconds(300)
    /// About 8k tokens of note text; longer notes are trimmed with a visible marker.
    static let maxInputCharacters = 32_000

    @Published public private(set) var isGenerating = false

    private let modelManager: LocalModelManager
    private var idleUnloadTask: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Gemma")

    public init(modelManager: LocalModelManager = .shared) {
        self.modelManager = modelManager
    }

    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: LocalModelManager.enabledDefaultsKey)
    }

    /// Streams Gemma's answer for `request`. Cancelling the consuming task stops generation.
    public func stream(_ request: RewriteRequest, image: CGImage? = nil) -> AsyncThrowingStream<String, Error> {
        // Validate before `generate` so an empty note never loads the 6.8 GB model.
        let prompt: String
        do {
            prompt = try Self.prompt(for: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return generate { container in
            // No pre-resize: ChatSession's 512×512 default would shrink screenshots before
            // Gemma's own processor sizes them to its token budget, blurring slide text.
            let session = ChatSession(
                container,
                instructions: Self.withCustomInstructions(Self.instructions),
                generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.3),
                processing: UserInput.Processing())
            let images: [UserInput.Image] = image.map { [.ciImage(CIImage(cgImage: $0))] } ?? []
            return session.streamResponse(to: prompt, images: images)
        }
    }

    /// Streams Gemma's answer to a skill, with the note added when the skill uses it.
    public func stream(_ skill: Skill, noteText: String) -> AsyncThrowingStream<String, Error> {
        let prompt: String
        do {
            prompt = try skill.prompt(note: noteText)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return generate { container in
            ChatSession(
                container,
                instructions: Self.withCustomInstructions(Self.instructions),
                generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.3),
                processing: UserInput.Processing()
            ).streamResponse(to: prompt)
        }
    }

    /// Loads the model if needed, runs `makeStream` with it and forwards the output. Keeps
    /// `isGenerating` and the idle-unload timer correct for every caller (note actions and chat).
    func generate(
        _ makeStream: @escaping (ModelContainer) throws -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    guard self.isEnabled else { throw GemmaServiceError.disabled }
                    self.idleUnloadTask?.cancel()
                    self.isGenerating = true
                    defer {
                        self.isGenerating = false
                        self.scheduleIdleUnload()
                    }
                    let container = try await self.modelManager.loadModel()
                    for try await chunk in try makeStream(container) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        self.log.error("Generation failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Loads the model and generates one token, so the next request skips both the load (about
    /// 4 s) and the slower first pass on the GPU. Does nothing if the model is already loaded.
    public func prewarm() async {
        guard isEnabled, !modelManager.isLoaded, !isGenerating else { return }
        let stream = generate { container in
            ChatSession(
                container, generateParameters: GenerateParameters(maxTokens: 1, temperature: 0),
                processing: UserInput.Processing()
            ).streamResponse(to: "Hi")
        }
        do {
            for try await _ in stream {}
        } catch {
            log.info("Prewarm skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled, let self, !self.isGenerating else { return }
            self.modelManager.unloadModel()
        }
    }

    // MARK: - Prompts

    /// The user's own instructions from Settings, added to every request (note actions and chat).
    public static let customInstructionsKey = "ai_custom_instructions"
    public static let maxCustomInstructionsLength = 2_000

    /// `base` followed by the user's custom instructions, when there are any.
    static func withCustomInstructions(
        _ base: String, custom: String? = UserDefaults.standard.string(forKey: customInstructionsKey)
    ) -> String {
        let custom = String((custom ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCustomInstructionsLength))
        guard !custom.isEmpty else { return base }
        return "\(base)\n\nThe user's own instructions, which take priority over the style rules above:\n\(custom)"
    }

    static let instructions = """
        You are a writing assistant inside a Markdown notes app. Answer in Markdown only, without \
        any preamble or closing remarks. Always reply in the same language as the note.
        """

    /// The user prompt for `request`. Pure, so the wording can be tested without loading the model.
    static func prompt(for request: RewriteRequest) throws -> String {
        let note = trimmed(request.sourceText)
        let transcript = (request.transcripts ?? [])
            .filter(\.isFinal)
            .map { "\($0.speaker == .microphone ? "Me" : "Them"): \($0.text)" }
            .joined(separator: "\n")

        switch request.mode {
        case .explainDiagram:
            return """
                Explain what this screenshot shows, for someone taking notes. Describe any diagram, \
                slide or chart: its main elements, how they relate, and the key takeaway. Use short \
                sections or bullet points.\(note.isEmpty ? "" : "\n\nThe note it belongs to, for context:\n\n\(note)")
                """
        case .summarizeMeeting:
            guard !note.isEmpty || !transcript.isEmpty else { throw GemmaServiceError.emptyInput }
            var parts = ["""
                Summarize the following as meeting minutes with these sections: **Summary** (2–4 \
                sentences), **Decisions**, **Action items** (a Markdown checklist with owners and \
                dates when mentioned) and **Open questions**. Leave out any section with nothing \
                to report. Don't invent facts.
                """]
            if !note.isEmpty { parts.append("Note:\n\n\(note)") }
            if !transcript.isEmpty { parts.append("Transcript (\"Me\" is the note taker):\n\n\(transcript)") }
            return parts.joined(separator: "\n\n")
        case .extractActionItems:
            guard !note.isEmpty else { throw GemmaServiceError.emptyInput }
            return """
                List every action item in this note as a Markdown checklist (`- [ ] …`). Include the \
                owner and due date when the note mentions them. If there are none, reply with \
                "No action items found." Don't invent tasks.

                Note:

                \(note)
                """
        case .rewrite:
            guard !note.isEmpty else { throw GemmaServiceError.emptyInput }
            return """
                Rewrite this note so it reads clearly: fix grammar and spelling, tighten wording and \
                improve structure. Keep every fact, link, code block, front matter and Markdown \
                heading level. Return only the rewritten note.

                Note:

                \(note)
                """
        }
    }

    static func trimmed(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxInputCharacters else { return text }
        return String(text.prefix(maxInputCharacters)) + "\n\n[… note truncated: only the first part was included]"
    }
}
