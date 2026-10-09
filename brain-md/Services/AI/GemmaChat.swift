//
//  GemmaChat.swift
//  brain-md
//

import Combine
import Foundation
import MLXLMCommon

/// How much of Gemma's context window a conversation fills.
public struct ContextUsage: Equatable {
    /// Gemma 4 E4B's `max_position_embeddings`.
    public static let window = 131_072

    public enum Level: Equatable { case normal, high, nearlyFull }

    public let tokens: Int

    public var fraction: Double { min(1, max(0, Double(tokens) / Double(Self.window))) }

    public var level: Level {
        switch fraction {
        case 0.9...: .nearlyFull
        case 0.7...: .high
        default: .normal
        }
    }

    /// "1.7K / 131K", in the user's number format.
    public func label(locale: Locale = .current) -> String {
        "\(Self.compact(tokens, locale: locale)) / \(Self.compact(Self.window, locale: locale))"
    }

    /// 950 → "950", 1_717 → "1.7K", 12_400 → "12.4K", 131_072 → "131K" (in en_US).
    static func compact(_ count: Int, locale: Locale = .current) -> String {
        let digits = count < 10_000 ? 1...2 : 1...3
        return count.formatted(.number.notation(.compactName).precision(.significantDigits(digits)).locale(locale))
    }
}

/// Length and speed of one answer.
public struct AnswerStats: Equatable {
    public let tokens: Int
    public let tokensPerSecond: Double
}

/// A free-form conversation with Gemma. Messages live in memory only; "New Chat" clears them.
public final class GemmaChat: ObservableObject {
    public static let shared = GemmaChat()

    public struct Message: Identifiable, Equatable {
        public enum Role: Equatable { case user, assistant }
        public let id = UUID()
        public let role: Role
        /// What the chat shows.
        public var text: String
        /// What Gemma saw for this turn (the user's text, plus the note when it was shared).
        public var prompt: String
        public var isError = false
    }

    /// The open note, offered to Gemma when "Include current note" is on.
    public struct NoteContext: Equatable {
        public let title: String
        public let content: String
    }

    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var isResponding = false
    /// Tokens the conversation occupies in Gemma's context, measured after each answer.
    @Published public private(set) var contextUsage: ContextUsage?
    /// Length and speed of the most recent answer.
    @Published public private(set) var lastAnswerStats: AnswerStats?

    /// Most recent turns replayed after the model reloads; older ones are dropped to bound context.
    static let maxReplayedMessages = 40

    static let instructions = """
        You are Gemma, a helpful assistant inside brain-md, a Markdown notes app. Answer in Markdown. \
        Reply in the language the user writes in. Be concise unless asked for detail. When the user \
        shares a note, use it as context and don't invent facts that aren't in it.
        """

    static var generateParameters: GenerateParameters {
        GenerateParameters(maxTokens: 2048, temperature: 0.6)
    }

    private let service: GemmaService
    private var session: ChatSession?
    private weak var sessionContainer: ModelContainer?
    private var sessionInstructions: String?
    private var sharedNoteContent: String?
    private var generation: Task<Void, Never>?
    private var activeReplyID: Message.ID?
    private var unloadObserver: AnyCancellable?

    public init(service: GemmaService = .shared, modelManager: LocalModelManager = .shared) {
        self.service = service
        // An unloaded model invalidates the session; the next message rebuilds it from history.
        unloadObserver = modelManager.$isLoaded
            .filter { !$0 }
            .sink { [weak self] _ in self?.session = nil }
    }

    /// Sends `text` to Gemma. `displayText` replaces it in the transcript, e.g. a skill's name
    /// instead of its full prompt.
    public func send(_ text: String, note: NoteContext?, displayText: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        let prompt = Self.prompt(for: text, note: note, alreadyShared: sharedNoteContent)
        let previouslyShared = sharedNoteContent
        if let note { sharedNoteContent = note.content }
        let history = Self.replayHistory(messages)
        let reply = Message(role: .assistant, text: "", prompt: "")
        messages.append(Message(role: .user, text: displayText ?? text, prompt: prompt))
        messages.append(reply)

        isResponding = true
        activeReplyID = reply.id
        generation = Task {
            do {
                let stream = service.generate { container in
                    Self.text(from: self.session(for: container, history: history).streamDetails(to: prompt)) { info in
                        self.lastAnswerStats = AnswerStats(
                            tokens: info.generationTokenCount, tokensPerSecond: info.tokensPerSecond)
                    }
                }
                for try await chunk in stream {
                    updateReply(reply.id) { $0.text += chunk }
                }
                if let tokens = try? await session?.cacheStatus().processedTokenCount {
                    contextUsage = ContextUsage(tokens: tokens)
                }
            } catch is CancellationError {
                session = nil // a stopped turn leaves the session's own history uncertain
            } catch {
                session = nil
                updateReply(reply.id) {
                    $0.text = error.localizedDescription
                    $0.isError = true
                }
            }
            // `reset()` may have started over while this turn was winding down.
            guard activeReplyID == reply.id else { return }
            // A turn left out of the replayed history must not count as having shared the note.
            if messages.last.map({ $0.isError || $0.text.isEmpty }) ?? true { sharedNoteContent = previouslyShared }
            isResponding = false
            activeReplyID = nil
            generation = nil
        }
    }

    public func stop() {
        generation?.cancel()
    }

    public func reset() {
        generation?.cancel()
        generation = nil
        activeReplyID = nil
        isResponding = false
        messages = []
        session = nil
        sharedNoteContent = nil
        contextUsage = nil
        lastAnswerStats = nil
    }

    private func updateReply(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func session(for container: ModelContainer, history: [Chat.Message]) -> ChatSession {
        // Edited custom instructions take effect on the next message: the session is rebuilt
        // from history with the new ones.
        let instructions = GemmaService.withCustomInstructions(Self.instructions)
        if let session, sessionContainer === container, sessionInstructions == instructions { return session }
        sessionInstructions = instructions
        let session = ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: Self.generateParameters,
            processing: UserInput.Processing())
        self.session = session
        sessionContainer = container
        return session
    }

    /// The text of a detailed generation stream; completion info goes to `onInfo`.
    private static func text(
        from details: AsyncThrowingStream<Generation, Error>,
        onInfo: @escaping (GenerateCompletionInfo) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in details {
                        switch event {
                        case .chunk(let text): continuation.yield(text)
                        case .info(let info): onInfo(info)
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pure helpers

    /// The turn Gemma sees: the note is attached only when it's new or changed since it was last shared.
    static func prompt(for text: String, note: NoteContext?, alreadyShared: String?) -> String {
        guard let note, note.content != alreadyShared else { return text }
        let content = GemmaService.trimmed(note.content)
        guard !content.isEmpty else { return text }
        let title = note.title.isEmpty ? "Untitled" : note.title
        return """
            My current note, "\(title)", for context:

            \(content)

            ---

            \(text)
            """
    }

    /// Completed exchanges to restore a session with. A question whose answer failed or was stopped
    /// before any text is left out with it, so user and assistant turns keep alternating.
    static func replayHistory(_ messages: [Message]) -> [Chat.Message] {
        var history: [Chat.Message] = []
        var index = messages.startIndex
        while index + 1 < messages.endIndex {
            let question = messages[index], answer = messages[index + 1]
            if question.role == .user, answer.role == .assistant, !answer.isError, !answer.text.isEmpty {
                history += [.user(question.prompt), .assistant(answer.text)]
            }
            index += 2
        }
        return Array(history.suffix(maxReplayedMessages))
    }
}

#if DEBUG
extension GemmaChat {
    /// Fills the chat with fixed messages for previews and render checks.
    func loadForPreview(
        _ messages: [Message], responding: Bool = false, contextTokens: Int? = nil, lastAnswer: AnswerStats? = nil
    ) {
        self.messages = messages
        isResponding = responding
        contextUsage = contextTokens.map(ContextUsage.init(tokens:))
        lastAnswerStats = lastAnswer
    }
}
#endif
