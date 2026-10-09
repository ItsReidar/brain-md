//
//  GemmaChatTests.swift
//  brain-mdTests
//

import Foundation
import MLXLMCommon
import Testing
@testable import brain_md

// An extension of the serialized GemmaServiceTests suite: these tests also flip the shared
// "on-device AI enabled" default, so they must not run alongside it.
extension GemmaServiceTests {

    private typealias Message = GemmaChat.Message

    @Test func chatAttachesTheNoteOnlyWhenNewOrChanged() {
        let note = GemmaChat.NoteContext(title: "Launch plan", content: "Ship v2 on Friday.")
        let first = GemmaChat.prompt(for: "What's the date?", note: note, alreadyShared: nil)
        #expect(first.contains("\"Launch plan\""))
        #expect(first.contains("Ship v2 on Friday."))
        #expect(first.hasSuffix("What's the date?"))

        #expect(GemmaChat.prompt(for: "And the owner?", note: note, alreadyShared: note.content) == "And the owner?")
        #expect(GemmaChat.prompt(for: "Hi", note: nil, alreadyShared: nil) == "Hi")
        #expect(GemmaChat.prompt(for: "Hi", note: .init(title: "", content: " \n"), alreadyShared: nil) == "Hi")

        let edited = GemmaChat.NoteContext(title: "Launch plan", content: "Ship v2 on Monday.")
        #expect(GemmaChat.prompt(for: "Now?", note: edited, alreadyShared: note.content).contains("Monday"))
    }

    @Test func chatHistoryReplaysCompleteExchangesOnly() {
        let messages = [
            Message(role: .user, text: "Hi", prompt: "NOTE + Hi"),
            Message(role: .assistant, text: "Hello!", prompt: ""),
            Message(role: .user, text: "Fails", prompt: "Fails"),
            Message(role: .assistant, text: "Out of memory", prompt: "", isError: true),
            Message(role: .user, text: "Stopped early", prompt: "Stopped early"),
            Message(role: .assistant, text: "", prompt: ""),
            Message(role: .user, text: "Thanks", prompt: "Thanks"),
            Message(role: .assistant, text: "You're welcome.", prompt: ""),
        ]
        let history = GemmaChat.replayHistory(messages)
        #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(history.map(\.content) == ["NOTE + Hi", "Hello!", "Thanks", "You're welcome."])
    }

    @Test func chatHistoryKeepsTheMostRecentTurns() {
        let messages = (0..<50).flatMap { turn in
            [Message(role: .user, text: "Q\(turn)", prompt: "Q\(turn)"),
             Message(role: .assistant, text: "A\(turn)", prompt: "")]
        }
        let history = GemmaChat.replayHistory(messages)
        #expect(history.count == GemmaChat.maxReplayedMessages)
        #expect(history.first?.content == "Q30")
        #expect(history.last?.content == "A49")
    }

    /// A failed turn shows the error, and the note it carried is offered again on the next message.
    @Test func failedChatTurnShowsTheErrorAndResendsTheNote() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(false, forKey: key)

        let manager = LocalModelManager(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = GemmaChat(service: GemmaService(modelManager: manager), modelManager: manager)
        let note = GemmaChat.NoteContext(title: "Plan", content: "Ship v2 on Friday.")

        chat.send("  What's planned?  ", note: note)
        try await waitUntilIdle(chat)
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].text == "What's planned?")
        #expect(chat.messages[1].isError)
        #expect(chat.messages[1].text == GemmaServiceError.disabled.errorDescription)
        #expect(!manager.isLoaded)

        chat.send("Try again", note: note)
        try await waitUntilIdle(chat)
        #expect(chat.messages[2].prompt.contains("Ship v2 on Friday."))

        chat.reset()
        #expect(chat.messages.isEmpty)
        #expect(!chat.isResponding)
    }

    @Test func customInstructionsAreAddedAfterTheBuiltInOnes() {
        #expect(GemmaService.withCustomInstructions("Base.", custom: nil) == "Base.")
        #expect(GemmaService.withCustomInstructions("Base.", custom: "  \n") == "Base.")
        let combined = GemmaService.withCustomInstructions("Base.", custom: " Answer in Dutch. ")
        #expect(combined.hasPrefix("Base.\n\n"))
        #expect(combined.hasSuffix("\nAnswer in Dutch."))
        let long = String(repeating: "x", count: GemmaService.maxCustomInstructionsLength + 50)
        let capped = GemmaService.withCustomInstructions("Base.", custom: long)
        #expect(capped.hasSuffix("\n" + String(repeating: "x", count: GemmaService.maxCustomInstructionsLength)))
        #expect(!capped.contains(String(repeating: "x", count: GemmaService.maxCustomInstructionsLength + 1)))
    }

    /// A skill run from chat shows its name, while Gemma gets the full prompt and the note.
    @Test func chatSkillShowsItsNameAndSendsItsPrompt() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(false, forKey: key)

        let manager = LocalModelManager(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = GemmaChat(service: GemmaService(modelManager: manager), modelManager: manager)
        let skill = try #require(Skill.parse("---\nname: Open Questions\n---\nList what {{note}} leaves open.",
                                             relativePath: "Skills/Open Questions.md"))
        chat.send(skill.chatMessage, note: .init(title: "Plan", content: "Ship v2."), displayText: skill.name)
        try await waitUntilIdle(chat)
        #expect(chat.messages[0].text == "Open Questions")
        #expect(chat.messages[0].prompt.contains("Ship v2."))
        #expect(chat.messages[0].prompt.hasSuffix("List what the note leaves open."))
    }

    @Test func blankChatMessagesAreIgnored() {
        let chat = GemmaChat()
        chat.send(" \n ", note: nil)
        #expect(chat.messages.isEmpty)
        #expect(!chat.isResponding)
    }

    /// Opt-in: a second question that only makes sense with the first answer in context.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func realModelRemembersTheConversation() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)

        let chat = GemmaChat()
        chat.send("Wat is de hoofdstad van België? Antwoord met één woord.", note: nil)
        try await waitUntilIdle(chat, timeout: .seconds(300))
        #expect(chat.messages[1].text.lowercased().contains("brussel"), "\(chat.messages[1].text)")

        // Unloading drops the session, so the second turn also exercises the history replay.
        LocalModelManager.shared.unloadModel()
        chat.send("And of the Netherlands? Answer with one word, in English.", note: nil)
        try await waitUntilIdle(chat, timeout: .seconds(300))
        #expect(chat.messages[3].text.lowercased().contains("amsterdam"), "\(chat.messages[3].text)")
        chat.reset()
    }

    @Test func contextUsageIsCompactAndWarnsNearTheLimit() {
        let us = Locale(identifier: "en_US")
        #expect(ContextUsage(tokens: 950).label(locale: us) == "950 / 131K")
        #expect(ContextUsage(tokens: 1_717).label(locale: us) == "1.7K / 131K")
        #expect(ContextUsage(tokens: 12_400).label(locale: us) == "12.4K / 131K")
        #expect(ContextUsage(tokens: 1_717).level == .normal)
        #expect(ContextUsage(tokens: 92_000).level == .high)       // 70 %
        #expect(ContextUsage(tokens: 118_000).level == .nearlyFull) // 90 %
        #expect(ContextUsage(tokens: 200_000).fraction == 1)

        let help = ContextGauge.helpText(
            ContextUsage(tokens: 1_717), AnswerStats(tokens: 136, tokensPerSecond: 31.66), locale: us)
        #expect(help == "Context: 1,717 of 131,072 tokens (1 %). Last answer: 136 tokens at 31.7 tokens/s.")
        #expect(ContextGauge.helpText(ContextUsage(tokens: 120_000), nil, locale: us).hasSuffix("Start a new chat to keep answers accurate."))
        // Belgian formatting uses the local separators.
        #expect(ContextGauge.helpText(ContextUsage(tokens: 1_717), nil, locale: Locale(identifier: "nl_BE")).contains("1.717 of 131.072"))
    }

    @Test func newChatClearsContextUsage() {
        let chat = GemmaChat()
        chat.reset()
        #expect(chat.contextUsage == nil)
        #expect(chat.lastAnswerStats == nil)
    }

    private func waitUntilIdle(_ chat: GemmaChat, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while chat.isResponding {
            try #require(ContinuousClock.now < deadline, "chat did not finish in time")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
