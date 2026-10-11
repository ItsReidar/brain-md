//
//  WindowedTranscription.swift
//  brain-md
//

import Foundation
import os

/// The pipeline the MLX engines share: per source, resample to 16 kHz mono, cut utterances,
/// transcribe each open window for live words and each closed one for the final line, and label
/// call audio with the diarizer's speaker.
nonisolated enum WindowedTranscription {
    typealias Transcribe = @Sendable (_ samples: [Float]) async throws -> String

    static func run(
        _ audio: AsyncStream<CapturedAudio>,
        sources: Set<TranscriptionSegment.Speaker>,
        segmenter configuration: UtteranceSegmenter.Configuration,
        diarizer: SpeakerDiarizer?,
        transcribe: @escaping Transcribe,
        into continuation: AsyncThrowingStream<TranscriptionSegment, Error>.Continuation
    ) async throws {
        // One stream per source, so a slow transcription of one never holds up the other's audio.
        var feeds: [TranscriptionSegment.Speaker: AsyncStream<[Float]>.Continuation] = [:]
        var streams: [(TranscriptionSegment.Speaker, AsyncStream<[Float]>)] = []
        for source in [TranscriptionSegment.Speaker.systemAudio, .microphone] where sources.contains(source) {
            let (stream, feed) = AsyncStream<[Float]>.makeStream()
            feeds[source] = feed
            streams.append((source, stream))
        }
        let resamplers = Dictionary(uniqueKeysWithValues: feeds.keys.map { ($0, AudioResampler()) })

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (source, stream) in streams {
                let labelsSpeakers = source == .systemAudio ? diarizer : nil
                group.addTask {
                    var segmenter = UtteranceSegmenter(configuration: configuration)
                    for await samples in stream {
                        try Task.checkCancellation()
                        await labelsSpeakers?.feed(samples)
                        try await handle(segmenter.append(samples), source: source, diarizer: labelsSpeakers,
                                         transcribe: transcribe, continuation: continuation)
                    }
                    await labelsSpeakers?.finish()
                    try await handle(segmenter.flush(), source: source, diarizer: labelsSpeakers,
                                     transcribe: transcribe, continuation: continuation)
                }
            }
            group.addTask {
                for await chunk in audio {
                    try Task.checkCancellation()
                    guard let feed = feeds[chunk.speaker], let resampler = resamplers[chunk.speaker] else { continue }
                    let samples = resampler.convert(chunk.buffer)
                    if !samples.isEmpty { feed.yield(samples) }
                }
                for feed in feeds.values { feed.finish() }
            }
            try await group.waitForAll()
        }
    }

    /// Finals are always transcribed; of several partials only the newest is, so a slow engine
    /// never falls behind on stale live text.
    private static func handle(
        _ events: [UtteranceSegmenter.Event],
        source: TranscriptionSegment.Speaker,
        diarizer: SpeakerDiarizer?,
        transcribe: Transcribe,
        continuation: AsyncThrowingStream<TranscriptionSegment, Error>.Continuation
    ) async throws {
        let latestPartial = events.lastIndex { if case .partial = $0 { true } else { false } }
        for (index, event) in events.enumerated() {
            switch event {
            case .partial(let start, let samples):
                guard index == latestPartial else { continue }
                let text = try await transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                continuation.yield(TranscriptionSegment(
                    speaker: source, timestamp: start, duration: duration(samples), text: text, isFinal: false))
            case .final(let start, let samples):
                let text = try await transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let speakerIndex = await diarizer?.speaker(from: start, to: start + duration(samples))
                continuation.yield(TranscriptionSegment(
                    speaker: source, speakerIndex: speakerIndex, timestamp: start, duration: duration(samples),
                    text: text, isFinal: true))
            }
        }
    }

    private static func duration(_ samples: [Float]) -> Double { Double(samples.count) / AudioResampler.sampleRate }
}
