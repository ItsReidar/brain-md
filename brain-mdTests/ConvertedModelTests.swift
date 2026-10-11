//
//  ConvertedModelTests.swift
//  brain-mdTests
//

import Foundation
import HuggingFace
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_ORUKEET_DIR=<folder>`): a locally converted Orukeet (scripts/models/convert_orukeet.py)
/// loads through mlx-audio-swift's Parakeet loader and transcribes, before it's uploaded.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAINMD_ORUKEET_DIR"] != nil))
struct ConvertedModelTests {
    @Test func orukeetTranscribesEnglishAndDutch() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRAINMD_ORUKEET_DIR"]!)
        // mlx-audio loads `<cache>/mlx-audio/<org>_<name>` offline, so link the files there.
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let link = cache.appendingPathComponent("mlx-audio/local_orukeet-mlx", isDirectory: true)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try FileManager.default.createSymbolicLink(
                atPath: link.appendingPathComponent(file).path, withDestinationPath: source.appendingPathComponent(file).path)
        }

        let engine = STTEngine()
        try await engine.load(repo: "local/orukeet-mlx", type: "parakeet", cache: HubCache(cacheDirectory: cache))

        let english = try await engine.transcribe(
            GemmaAudioTests.spokenSamples(
                "The quarterly launch slips two weeks because the payment certification failed.", voice: "Samantha"),
            language: nil).lowercased()
        for word in ["launch", "weeks", "payment", "certification"] {
            #expect(english.contains(word), "missing \"\(word)\" in: \(english)")
        }
        let dutch = try await engine.transcribe(
            GemmaAudioTests.spokenSamples("We plannen de demo op vrijdag in Antwerpen.", voice: "Ellen"),
            language: nil).lowercased()
        #expect(dutch.contains("vrijdag") && dutch.contains("antwerpen"), "\(dutch)")
        try await MLXSpeechIntegrationTests.report("orukeet: \(english) | \(dutch)")
    }
}
