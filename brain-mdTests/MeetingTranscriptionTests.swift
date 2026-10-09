//
//  MeetingTranscriptionTests.swift
//  brain-mdTests
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import brain_md

@MainActor
struct MeetingTranscriptionTests {

    private func sineBuffer(amplitude: Float, frames: AVAudioFrameCount = 1600, sampleRate: Double = 16_000) throws
        -> AVAudioPCMBuffer
    {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
        }
        return buffer
    }

    /// Wraps a PCM buffer in a CMSampleBuffer, the way ScreenCaptureKit delivers audio.
    private func sampleBuffer(from buffer: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        #expect(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription) == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(buffer.format.sampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        let result = try #require(sample)
        #expect(CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList) == noErr)
        return result
    }

    @Test func sampleBufferConversionKeepsEverySample() throws {
        let original = try sineBuffer(amplitude: 0.5)
        let converted = try #require(AudioCaptureService.pcmBuffer(from: try sampleBuffer(from: original)))
        #expect(converted.frameLength == original.frameLength)
        #expect(converted.format.sampleRate == 16_000)
        let a = try #require(original.floatChannelData?[0])
        let b = try #require(converted.floatChannelData?[0])
        #expect((0..<Int(original.frameLength)).allSatisfy { a[$0] == b[$0] })
    }

    @Test func levelMapsDecibelsToMeterRange() throws {
        #expect(AudioCaptureService.level(of: try sineBuffer(amplitude: 0)) == 0)
        // A full-scale sine has an RMS of −3 dBFS → (60 − 3) / 60 ≈ 0.95.
        #expect(abs(AudioCaptureService.level(of: try sineBuffer(amplitude: 1)) - 0.95) < 0.01)
        // An RMS of −20 dBFS → 40 / 60 ≈ 0.67.
        let minus20 = Float(pow(10, -20.0 / 20) * 2.0.squareRoot())
        #expect(abs(AudioCaptureService.level(of: try sineBuffer(amplitude: minus20)) - 0.667) < 0.01)
    }

    @Test func transcriptLinesAreLabelledAndTimestamped() {
        #expect(MeetingRecorder.line(for: TranscriptionSegment(speaker: .systemAudio, timestamp: 192.7, text: "We slip two weeks."))
            == "- **Them** [03:12] We slip two weeks.")
        #expect(MeetingRecorder.line(for: TranscriptionSegment(speaker: .microphone, timestamp: 4_512, text: "Agreed."))
            == "- **Me** [75:12] Agreed.")
    }

    @Test func emptyLocaleSettingMeansSystemLanguage() {
        #expect(MeetingTranscriber.preferredLocale("") == Locale.current)
        #expect(MeetingTranscriber.preferredLocale("nl_BE").identifier == "nl_BE")
    }

    /// Opt-in: speaks a sentence with `say`, then transcribes it through the real pipeline in
    /// capture-sized chunks. Run with `TEST_RUNNER_BRAINMD_SPEECH_INTEGRATION=1 xcodebuild test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_SPEECH_INTEGRATION"] == "1"))
    func spokenSentenceIsTranscribed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", file.path,
                         "The quarterly launch slips two weeks because the payment certification failed."]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let audioFile = try AVAudioFile(forReading: file)
        let (audio, continuation) = AsyncStream<CapturedAudio>.makeStream()
        while audioFile.framePosition < audioFile.length {
            let chunk = try #require(AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4_800))
            try audioFile.read(into: chunk, frameCount: 4_800)
            continuation.yield(CapturedAudio(speaker: .systemAudio, buffer: chunk, time: .zero))
        }
        continuation.finish()

        // Fail instead of hanging if the analyzer never finishes.
        let finals = try await withThrowingTaskGroup(of: [TranscriptionSegment]?.self) { group in
            group.addTask {
                var finals: [TranscriptionSegment] = []
                let results = MeetingTranscriber().transcribe(
                    audio, locale: Locale(identifier: "en_US"), speakers: [.systemAudio])
                for try await segment in results where segment.isFinal { finals.append(segment) }
                return finals
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return try #require(first, "transcription did not finish within 3 minutes")
        }
        let text = finals.map(\.text).joined(separator: " ").lowercased()
        #expect(finals.allSatisfy { $0.speaker == .systemAudio })
        for word in ["launch", "2 weeks", "payment", "certification"] { // numbers come back as digits
            #expect(text.contains(word), "missing \"\(word)\" in: \(text)")
        }
    }
}
