//
//  GemmaAudioTests.swift
//  brain-mdTests
//

import AVFoundation
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import brain_md

/// Gemma 4 audio input, ported from mlx-swift-lm PR #392 (Services/AI/Vendor/Gemma4Audio).
@MainActor
@Suite(.serialized)
struct GemmaAudioTests {

    /// Synthesizes `sentence` with a `say` voice and returns 16 kHz mono samples.
    static func spokenSamples(_ sentence: String, voice: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", file.path, sentence]
        try say.run()
        say.waitUntilExit()

        let source = try AVAudioFile(forReading: file)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: input)
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: input.format, to: target))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 1024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let channel = try #require(output.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Opt-in: the already-downloaded Gemma 4 E4B transcribes speech through the ported audio tower.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func realGemmaTranscribesSpeech() async throws {
        let samples = try Self.spokenSamples(
            "The quarterly launch slips two weeks because the payment certification failed.", voice: "Samantha")
        let container = try await TestModels.gemmaRuntime.loadModel()
        let session = ChatSession(
            container, generateParameters: GenerateParameters(maxTokens: 120, temperature: 0),
            processing: UserInput.Processing())
        let text = try await session.respond(
            to: "Transcribe this audio verbatim. Output only the transcript.",
            images: [], videos: [], audios: [UserInput.Audio(source: .array(MLXArray(samples)))]
        ).lowercased()
        for word in ["launch", "weeks", "payment", "certification"] {
            #expect(text.contains(word), "missing \"\(word)\" in: \(text)")
        }
    }
}
