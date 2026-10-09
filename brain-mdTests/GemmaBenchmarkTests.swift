//
//  GemmaBenchmarkTests.swift
//  brain-mdTests
//

import Foundation
import MLXLMCommon
import Testing
@testable import brain_md

/// Opt-in speed measurements for the real model. Run with
/// `TEST_RUNNER_BRAINMD_MODEL_BENCHMARK=1 TEST_RUNNER_BRAINMD_BENCHMARK_OUT=/path/bench.txt xcodebuild test …
/// -parallel-testing-enabled NO -only-testing:brain-mdTests/GemmaBenchmarkTests`. Parallel testing must be off
/// so only one copy of the model runs. Results are `BENCH` lines in that file (or stdout without it).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_BENCHMARK"] == "1"))
struct GemmaBenchmarkTests {

    /// About 1,500 tokens of note text, like a typical meeting note.
    static let note = (1...60).map {
        "- Item \($0): the team reviewed the payment certification, agreed on owners and set a new date."
    }.joined(separator: "\n")

    @Test func measureLoadPrefillAndGeneration() async throws {
        let manager = LocalModelManager.shared
        manager.unloadModel()
        let loadStart = ContinuousClock.now
        let container = try await manager.loadModel()
        report("load \(ContinuousClock.now - loadStart)")

        let session = ChatSession(
            container, instructions: GemmaChat.instructions,
            generateParameters: GemmaChat.generateParameters, processing: UserInput.Processing())
        for (turn, prompt) in [
            "Here is my note:\n\n\(Self.note)\n\n---\n\nSummarize it in about 150 words.",
            "Now list three risks in one sentence each.",
        ].enumerated() {
            try await measureTurn(session, prompt, label: "turn \(turn + 1)")
        }
    }

    /// The first message after opening the chat, with and without `prewarm()` having run.
    @Test func measureFirstMessageColdAndPrewarmed() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)
        let manager = LocalModelManager.shared

        manager.unloadModel()
        var start = ContinuousClock.now
        try await measureTurn(try await newSession(), "What is a good title for a meeting note?",
                              label: "cold (incl. load)", since: start)

        manager.unloadModel()
        start = ContinuousClock.now
        await GemmaService.shared.prewarm()
        report("prewarm \(ContinuousClock.now - start)")
        try await measureTurn(try await newSession(), "What is a good title for a meeting note?", label: "prewarmed")
    }

    private func newSession() async throws -> ChatSession {
        ChatSession(
            try await LocalModelManager.shared.loadModel(), instructions: GemmaChat.instructions,
            generateParameters: GemmaChat.generateParameters, processing: UserInput.Processing())
    }

    private func measureTurn(
        _ session: ChatSession, _ prompt: String, label: String, since start: ContinuousClock.Instant = .now
    ) async throws {
        var firstToken: Duration?
        for try await event in session.streamDetails(to: prompt) {
            switch event {
            case .chunk:
                if firstToken == nil { firstToken = ContinuousClock.now - start }
            case .info(let info):
                report("""
                    \(label): first token \(firstToken.map { "\($0)" } ?? "-"), \
                    prompt \(info.promptTokenCount) tok (\(info.cachedPromptTokenCount) cached) \
                    at \(Int(info.promptTokensPerSecond)) tok/s, \
                    generated \(info.generationTokenCount) tok at \(String(format: "%.1f", info.tokensPerSecond)) tok/s
                    """)
            default: break
            }
        }
        report("\(label) context: \(try await session.cacheStatus().processedTokenCount ?? -1) tokens")
    }

    private func report(_ line: String) {
        let line = "BENCH \(line)\n"
        guard let path = ProcessInfo.processInfo.environment["BRAINMD_BENCHMARK_OUT"] else { return print(line) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}
