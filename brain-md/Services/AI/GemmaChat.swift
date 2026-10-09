//
//  GemmaChat.swift
//  brain-md
//

import Combine
import Foundation
import MLXLMCommon

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

    /// Most recent turns replayed after the model reloads; older ones are dropped to bound context.
    static let maxReplayedMessages = 40

    static let instructions = """
        You are Gemma, a helpful assistant inside brain-md, a Markdown notes app. Answer in Markdown. \
        Reply in the language the user writes in. Be concise unless asked for detail. When the user \
        shares a note, use it as context and don't invent facts that aren't in it.
        """

    private let service: GemmaService
    private var session: ChatSession?
    private weak var sessionContainer: ModelContainer?
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

    public func send(_ text: String, note: NoteContext?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }

        let prompt = Self.prompt(for: text, note: note, alreadyShared: sharedNoteContent)
        let previouslyShared = sharedNoteContent
        if let note { sharedNoteContent = note.content }
        let history = Self.replayHistory(messages)
        let reply = Message(role: .assistant, text: "", prompt: "")
        messages.append(Message(role: .user, text: text, prompt: prompt))
        messages.append(reply)

        isResponding = true
        activeReplyID = reply.id
        generation = Task {
            do {
                let stream = service.generate { container in
                    self.session(for: container, history: history).streamResponse(to: prompt)
                }
                for try await chunk in stream {
                    updateReply(reply.id) { $0.text += chunk }
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
    }

    private func updateReply(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func session(for container: ModelContainer, history: [Chat.Message]) -> ChatSession {
        if let session, sessionContainer === container { return session }
        let session = ChatSession(
            container,
            instructions: Self.instructions,
            history: history,
            generateParameters: GenerateParameters(maxTokens: 2048, temperature: 0.6),
            processing: UserInput.Processing())
        self.session = session
        sessionContainer = container
        return session
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
