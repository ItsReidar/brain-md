//
//  AlternativeLanguageModelTests.swift
//  brain-mdTests
//

import Foundation
import ImageIO
import MLXLMCommon
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_QWEN_INTEGRATION=1`): a non-Gemma family through the same runtime. Installs
/// Qwen3.5 2B 4-bit (1.75 GB) if missing; the other catalog models load through the same path.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAINMD_QWEN_INTEGRATION"] == "1"))
struct AlternativeLanguageModelTests {
    static let qwen = ModelCatalog.model("qwen3.5-2b")!

    static let runtime: LanguageModelRuntime = {
        let defaults = UserDefaults(suiteName: "brainmd-tests-qwen-runtime")!
        defaults.set(qwen.id, forKey: ModelSelection.languageModelKey)
        return LanguageModelRuntime(store: .shared, defaults: defaults)
    }()

    @Test func qwenLoadsAndAnswers() async throws {
        try await TestModels.install(Self.qwen)
        let container = try await Self.runtime.loadModel()
        #expect(Self.runtime.loadedModel == Self.qwen)
        #expect((Self.runtime.contextWindow ?? 0) >= 32_768)

        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 300, temperature: 0))
        let answer = try await session.respond(to: "What is the capital of Belgium? Answer in one word.")
        #expect(answer.localizedCaseInsensitiveContains("Brussel"), "\(answer)")
        // A second turn reuses the session's cache and still knows the first.
        let followUp = try await session.respond(to: "And which country did I ask about?")
        #expect(followUp.localizedCaseInsensitiveContains("Belgi"), "\(followUp)")
    }

    @Test func qwenExplainsAnImage() async throws {
        try await TestModels.install(Self.qwen)
        #expect(Self.qwen.supportsVision)
        let iconURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/app-icon.png")
        let source = try #require(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let key = ModelSelection.enabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)

        let service = LanguageModelService(runtime: Self.runtime)
        var output = ""
        for try await chunk in service.stream(RewriteRequest(mode: .explainDiagram, sourceText: ""), image: image) {
            output += chunk
        }
        #expect(output.localizedCaseInsensitiveContains("brain"), "\(output)")
        Self.runtime.unloadModel()
    }
}
