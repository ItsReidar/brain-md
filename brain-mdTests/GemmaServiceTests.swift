//
//  GemmaServiceTests.swift
//  brain-mdTests
//

import Foundation
import ImageIO
import Testing
@testable import brain_md

@MainActor
@Suite(.serialized)
struct GemmaServiceTests {

    @Test func everyModeIncludesTheNote() throws {
        let modes: [RewriteRequest.Mode] = [.rewrite, .summarizeMeeting, .extractActionItems, .explainDiagram]
        for mode in modes {
            let prompt = try GemmaService.prompt(for: RewriteRequest(mode: mode, sourceText: "  Ship v2 on Friday.  "))
            #expect(prompt.contains("Ship v2 on Friday."), "mode \(mode)")
        }
    }

    @Test func emptyNoteIsRejectedExceptForScreenExplanations() throws {
        for mode in [RewriteRequest.Mode.rewrite, .summarizeMeeting, .extractActionItems] {
            #expect(throws: GemmaServiceError.emptyInput) {
                _ = try GemmaService.prompt(for: RewriteRequest(mode: mode, sourceText: " \n "))
            }
        }
        let explain = try GemmaService.prompt(for: RewriteRequest(mode: .explainDiagram, sourceText: ""))
        #expect(explain.contains("screenshot"))
        #expect(!explain.contains("for context"))
    }

    @Test func meetingSummaryLabelsSpeakersAndSkipsPartialSegments() throws {
        let transcript = [
            TranscriptionSegment(speaker: .systemAudio, text: "We slip two weeks.", isFinal: true),
            TranscriptionSegment(speaker: .microphone, text: "I'll tell support.", isFinal: true),
            TranscriptionSegment(speaker: .microphone, text: "I'll tel", isFinal: false),
        ]
        let prompt = try GemmaService.prompt(
            for: RewriteRequest(mode: .summarizeMeeting, sourceText: "", transcripts: transcript))
        #expect(prompt.contains("Them: We slip two weeks."))
        #expect(prompt.contains("Me: I'll tell support."))
        #expect(!prompt.contains("I'll tel\n"))
        #expect(!prompt.contains("Note:"))
    }

    @Test func longNotesAreTruncatedWithAVisibleMarker() {
        let long = String(repeating: "a", count: GemmaService.maxInputCharacters + 500)
        let trimmed = GemmaService.trimmed(long)
        #expect(trimmed.hasPrefix(String(repeating: "a", count: GemmaService.maxInputCharacters)))
        #expect(trimmed.hasSuffix("[… note truncated: only the first part was included]"))
        #expect(GemmaService.trimmed("short") == "short")
    }

    @Test func disabledServiceFailsWithoutLoadingTheModel() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(false, forKey: key)

        let manager = LocalModelManager(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = GemmaService(modelManager: manager)
        await #expect(throws: GemmaServiceError.disabled) {
            for try await _ in service.stream(RewriteRequest(mode: .rewrite, sourceText: "Hello")) {}
        }
        #expect(!manager.isLoaded)
        #expect(!service.isGenerating)
    }

    /// Opt-in: sends the app icon through the image path. Run with `TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1 …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func realModelExplainsAnImage() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)

        let iconURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/app-icon.png")
        let source = try #require(CGImageSourceCreateWithURL(iconURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let service = GemmaService(modelManager: LocalModelManager())
        var output = ""
        for try await chunk in service.stream(RewriteRequest(mode: .explainDiagram, sourceText: ""), image: image) {
            output += chunk
        }
        #expect(output.localizedCaseInsensitiveContains("brain"), "\(output)")
        #expect(output.localizedCaseInsensitiveContains("head"), "\(output)")
    }

    /// Opt-in: streams a real answer. Run with `TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1 xcodebuild test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func realModelExtractsActionItems() async throws {
        let key = LocalModelManager.enabledDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.set(true, forKey: key)

        let service = GemmaService(modelManager: LocalModelManager())
        let note = """
            # Launch sync
            Anna: payment provider certification failed, launch slips two weeks.
            Ben will re-run the certification by Friday. Carla updates the support FAQ.
            """
        var output = ""
        var chunks = 0
        for try await chunk in service.stream(RewriteRequest(mode: .extractActionItems, sourceText: note)) {
            output += chunk
            chunks += 1
        }
        print("Gemma action items (\(chunks) chunks):\n\(output)")
        #expect(chunks > 1, "output should stream in several chunks")
        #expect(output.contains("- [ ]"))
        #expect(output.localizedCaseInsensitiveContains("Ben"))
        #expect(output.localizedCaseInsensitiveContains("Carla"))
    }
}
