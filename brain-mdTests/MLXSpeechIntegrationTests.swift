//
//  MLXSpeechIntegrationTests.swift
//  brain-mdTests
//

import AVFoundation
import Foundation
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_SPEECH_INTEGRATION=1`): real speech models on `say` audio. Installs Nemotron
/// 3.5 streaming 8-bit (0.76 GB) and Sortformer (0.24 GB) into the app's models folder if missing.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAINMD_SPEECH_INTEGRATION"] == "1"))
struct MLXSpeechIntegrationTests {
    static let nemotron = ModelCatalog.model("nemotron-3.5-streaming-8bit")!
    static let sortformer = ModelCatalog.model(ModelCatalog.defaultDiarizerID)!

    /// Downloads `model` at its pinned revision unless it's already installed.
    static func install(_ model: ModelDescriptor, store: ModelStore = .shared) async throws {
        store.refresh(model)
        if store.isInstalled(model) { return }
        store.startDownload(model)
        while store.state(of: model).status == .downloading {
            try await Task.sleep(for: .milliseconds(500))
        }
        let state = store.state(of: model)
        #expect(state.status == .ready, "\(model.id): \(state.errorMessage ?? "")")
        if state.status != .ready { throw LocalModelError.notDownloaded }
    }

    /// One utterance per (voice, sentence), separated by `gap` seconds of silence, as 100 ms chunks
    /// of call audio.
    /// With `realTime`, chunks arrive at the pace a live call would deliver them.
    static func callAudio(_ lines: [(voice: String, sentence: String)], gap: Double = 1.2, realTime: Bool = false) throws
        -> AsyncStream<CapturedAudio>
    {
        var samples: [Float] = Array(repeating: 0, count: 8_000)
        for line in lines {
            samples += try GemmaAudioTests.spokenSamples(line.sentence, voice: line.voice)
            samples += Array(repeating: 0, count: Int(gap * 16_000))
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let chunks = stride(from: 0, to: samples.count, by: 1_600).map { start in
            let count = min(1_600, samples.count - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress! + start, count: count)
            }
            return CapturedAudio(speaker: .systemAudio, buffer: buffer, time: .zero)
        }
        let (stream, continuation) = AsyncStream<CapturedAudio>.makeStream()
        guard realTime else {
            chunks.forEach { continuation.yield($0) }
            continuation.finish()
            return stream
        }
        Task.detached {
            let start = ContinuousClock.now
            for (index, chunk) in chunks.enumerated() {
                try? await Task.sleep(until: start + .milliseconds(100 * index))
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return stream
    }

    struct Run {
        var finals: [TranscriptionSegment] = []
        var partials = 0
        var firstFinal: Duration?
        var total: Duration = .zero
        /// Seconds from the start of the run to each final line arriving.
        var finalArrivals: [Double] = []

        /// Per line: how long after its speech ended the final line arrived (real-time runs).
        func lags(after speechEnds: [Double]) -> [Double] {
            zip(finalArrivals, speechEnds).map { ((($0 - $1) * 100).rounded()) / 100 }
        }
        var text: String { finals.map(\.text).joined(separator: " ").lowercased() }
    }

    static func run(_ recognizer: any SpeechRecognizer, _ audio: AsyncStream<CapturedAudio>, locale: String = "en_US")
        async throws -> Run
    {
        var run = Run()
        let start = ContinuousClock.now
        for try await segment in recognizer.transcribe(
            audio, locale: Locale(identifier: locale), sources: [.systemAudio], onPreparing: { _ in })
        {
            if segment.isFinal {
                run.finals.append(segment)
                let elapsed = ContinuousClock.now - start
                run.firstFinal = run.firstFinal ?? elapsed
                run.finalArrivals.append(elapsed.seconds)
            } else {
                run.partials += 1
            }
        }
        run.total = ContinuousClock.now - start
        return run
    }

    @Test func nemotronTranscribesEnglishWithLiveWords() async throws {
        try await Self.install(Self.nemotron)
        let recognizer = MLXSpeechRecognizer(model: Self.nemotron, store: .shared, diarizer: nil)
        let run = try await Self.run(recognizer, Self.callAudio([
            ("Samantha", "The quarterly launch slips two weeks because the payment certification failed."),
        ]))
        for word in ["launch", "weeks", "payment", "certification"] {
            #expect(run.text.contains(word), "missing \"\(word)\" in: \(run.text)")
        }
        #expect(run.partials > 0)
    }

    @Test func nemotronTranscribesDutch() async throws {
        try await Self.install(Self.nemotron)
        let recognizer = MLXSpeechRecognizer(model: Self.nemotron, store: .shared, diarizer: nil)
        let run = try await Self.run(
            recognizer, Self.callAudio([("Ellen", "We plannen de demo op vrijdag in Antwerpen.")]), locale: "nl_BE")
        try Self.report("nemotron dutch: \(run.text)")
        #expect(run.text.contains("vrijdag") || run.text.contains("antwerpen"), "\(run.text)")
    }

    @Test func sortformerTellsTwoVoicesApart() async throws {
        try await Self.install(Self.nemotron)
        try await Self.install(Self.sortformer)
        let diarizer = SpeakerDiarizer(model: Self.sortformer) {
            try await MainActor.run { try ModelStore.shared.ensureMLXAudioLink(Self.sortformer) }
        }
        let recognizer = MLXSpeechRecognizer(model: Self.nemotron, store: .shared, diarizer: diarizer)
        let run = try await Self.run(recognizer, Self.callAudio([
            ("Samantha", "Good morning everyone, let's review the release plan for this quarter."),
            ("Daniel", "Thanks. The backend team finished the migration yesterday afternoon."),
            ("Samantha", "Great, then we can schedule the launch for next Tuesday."),
        ]))
        let speakers = run.finals.map(\.speakerIndex)
        try Self.report("sortformer: \(zip(speakers, run.finals.map(\.text)).map { "\($0.0.map(String.init) ?? "nil"): \($0.1)" })")
        #expect(run.finals.count == 3)
        guard run.finals.count == 3 else { return }
        #expect(speakers.allSatisfy { $0 != nil })
        #expect(speakers[0] == speakers[2])
        #expect(speakers[0] != speakers[1])
    }

    @Test func gemmaTranscribesThroughTheMeetingPipeline() async throws {
        guard ModelStore.shared.isInstalled(TestModels.gemma) else { return }
        let recognizer = LanguageModelSpeechRecognizer(
            model: TestModels.gemma, runtime: TestModels.gemmaRuntime, diarizer: nil)
        let run = try await Self.run(recognizer, Self.callAudio([
            ("Samantha", "The quarterly launch slips two weeks because the payment certification failed."),
        ]))
        for word in ["launch", "weeks", "payment"] {
            #expect(run.text.contains(word), "missing \"\(word)\" in: \(run.text)")
        }
        #expect(run.partials == 0)
    }

    /// Same audio through Apple Speech and Nemotron: time to the first final line and total time.
    @Test func benchmarkAgainstAppleSpeech() async throws {
        try await Self.install(Self.nemotron)
        let lines: [(voice: String, sentence: String)] = [
            ("Samantha", "The quarterly launch slips two weeks because the payment certification failed."),
            ("Samantha", "We will ask the vendor for a new test environment before Friday."),
            ("Samantha", "Marketing keeps the original announcement date for now."),
        ]
        // Where each sentence's speech ends in the audio `callAudio` builds (0.5 s lead-in, 1.2 s gaps).
        var speechEnds: [Double] = []
        var cursor = 0.5
        for line in lines {
            cursor += Double(try GemmaAudioTests.spokenSamples(line.sentence, voice: line.voice).count) / 16_000
            speechEnds.append(cursor)
            cursor += 1.2
        }
        let audioSeconds = cursor
        let nemotron = MLXSpeechRecognizer(model: Self.nemotron, store: .shared, diarizer: nil)
        _ = try await Self.run(nemotron, Self.callAudio([lines[0]])) // load and warm up
        let mlx = try await Self.run(nemotron, Self.callAudio(lines))
        let apple = try await Self.run(AppleSpeechRecognizer(), Self.callAudio(lines))

        func describe(_ name: String, _ run: Run) -> String {
            let total = Double(run.total.components.seconds) + Double(run.total.components.attoseconds) / 1e18
            return String(format: "%@: total %.2fs, RTF %.3f, first final %@, partials %d, text: %@",
                          name, total, total / audioSeconds, "\(run.firstFinal ?? .zero)", run.partials, run.text)
        }
        try Self.report(String(format: "audio %.1fs\n", audioSeconds) + describe("nemotron", mlx) + "\n" + describe("apple", apple))
        #expect(mlx.text.contains("vendor") && mlx.text.contains("friday"), "\(mlx.text)")

        // Live: audio arrives in real time; how long after someone stops talking does their line land?
        let liveMLX = try await Self.run(nemotron, Self.callAudio(lines, realTime: true))
        let liveApple = try await Self.run(AppleSpeechRecognizer(), Self.callAudio(lines, realTime: true))
        try Self.report("""
            live, seconds from end of speech to final line (say adds some trailing silence of its own):
            nemotron \(liveMLX.lags(after: speechEnds)), apple \(liveApple.lags(after: speechEnds))
            """)
    }

    /// Swift Testing doesn't capture `print`; results go to `BRAINMD_BENCHMARK_OUT` when it's set.
    static func report(_ line: String) throws {
        guard let path = ProcessInfo.processInfo.environment["BRAINMD_BENCHMARK_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
