//
//  MeetingTranscriber.swift
//  brain-md
//

@preconcurrency import AVFoundation
import Foundation
import Speech
import os

public enum TranscriptionError: LocalizedError, Equatable {
    case unavailable
    case unsupportedLocale(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device transcription isn't available on this Mac."
        case .unsupportedLocale(let identifier):
            "On-device transcription doesn't support \(Locale.current.localizedString(forIdentifier: identifier) ?? identifier). "
                + "Pick another language in Settings › Local AI & Voice."
        }
    }
}

/// Transcribes meeting audio on-device with Apple's SpeechAnalyzer. Each source gets its own
/// analyzer, so lines are labelled by where the audio came from ("Them" or "Me").
nonisolated public final class MeetingTranscriber: Sendable {
    /// `@AppStorage` key for the transcription language; empty means the system language.
    public static let localeDefaultsKey = "ai_transcription_locale"

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Transcription")

    public init() {}

    /// The language to transcribe in: the saved choice, else the system language.
    public static func preferredLocale(_ identifier: String = UserDefaults.standard.string(forKey: localeDefaultsKey) ?? "")
        -> Locale
    {
        identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    }

    /// Transcribes `audio` until it finishes, streaming partial (volatile) and final segments.
    /// `onPreparing` reports when the language model has to be downloaded first.
    public func transcribe(
        _ audio: AsyncStream<CapturedAudio>,
        locale requested: Locale,
        speakers: Set<TranscriptionSegment.Speaker> = [.systemAudio, .microphone],
        onPreparing: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let pipelines = try await self.makePipelines(
                        locale: requested, speakers: speakers, onPreparing: onPreparing)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for pipeline in pipelines.values {
                            group.addTask { try await pipeline.collectResults(into: continuation) }
                        }
                        group.addTask {
                            for await chunk in audio {
                                try Task.checkCancellation()
                                pipelines[chunk.speaker]?.feed(chunk.buffer)
                            }
                            for pipeline in pipelines.values { try await pipeline.finish() }
                        }
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        self.log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makePipelines(
        locale requested: Locale,
        speakers: Set<TranscriptionSegment.Speaker>,
        onPreparing: @escaping @Sendable (String) -> Void
    ) async throws -> [TranscriptionSegment.Speaker: SourcePipeline]
    {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLocale(requested.identifier)
        }

        var pipelines: [TranscriptionSegment.Speaker: SourcePipeline] = [:]
        for speaker in [TranscriptionSegment.Speaker.systemAudio, .microphone] where speakers.contains(speaker) {
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange])
            if pipelines.isEmpty,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onPreparing("Downloading the \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier) speech model…")
                log.info("Installing speech assets for \(locale.identifier, privacy: .public)")
                try await request.downloadAndInstall()
            }
            pipelines[speaker] = try await SourcePipeline(speaker: speaker, transcriber: transcriber)
        }
        return pipelines
    }
}

/// One audio source → format conversion → SpeechAnalyzer → labelled segments.
nonisolated private final class SourcePipeline: @unchecked Sendable {
    let speaker: TranscriptionSegment.Speaker
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    /// Only touched from the single feeding task.
    private var converter: AVAudioConverter?
    private var receivedInput = false

    init(speaker: TranscriptionSegment.Speaker, transcriber: SpeechTranscriber) async throws {
        self.speaker = speaker
        self.transcriber = transcriber
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.unavailable
        }
        analyzerFormat = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        receivedInput = true
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async throws {
        input.finish()
        // Finalizing an analyzer that never received audio doesn't return; there's nothing to keep anyway.
        if receivedInput {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
            await analyzer.cancelAndFinishNow()
        }
    }

    func collectResults(into output: AsyncThrowingStream<TranscriptionSegment, Error>.Continuation) async throws {
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            output.yield(TranscriptionSegment(
                speaker: speaker,
                timestamp: result.range.start.seconds,
                duration: result.range.duration.seconds,
                text: text,
                isFinal: result.isFinal))
        }
    }

    /// Resamples/remixes capture audio into the analyzer's preferred format.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == analyzerFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
        }
        guard let converter else { return nil }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
