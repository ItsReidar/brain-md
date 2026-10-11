//
//  MLXSpeechRecognizer.swift
//  brain-md
//

import Foundation
import HuggingFace
import MLX
import MLXAudioSTT
import os

/// Transcribes meetings with a downloaded MLX speech model (Parakeet, Nemotron, Whisper, Voxtral)
/// through mlx-audio-swift. Each utterance is re-transcribed while it's open, so words appear as
/// people speak, and once more when they pause for the final line.
nonisolated final class MLXSpeechRecognizer: SpeechRecognizer {
    let model: ModelDescriptor
    private let store: ModelStore
    private let diarizer: SpeakerDiarizer?
    private let engine = STTEngine()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Transcription")

    init(model: ModelDescriptor, store: ModelStore, diarizer: SpeakerDiarizer?) {
        self.model = model
        self.store = store
        self.diarizer = diarizer
    }

    func transcribe(
        _ audio: AsyncStream<CapturedAudio>,
        locale: Locale,
        sources: Set<TranscriptionSegment.Speaker>,
        onPreparing: @escaping @Sendable (String) -> Void
    ) -> AsyncThrowingStream<TranscriptionSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .speech(let engineType, _) = model.kind else {
                        throw LocalModelError.unknownModel(model.id)
                    }
                    onPreparing("Loading \(model.displayName)…")
                    let store = store
                    let model = model
                    let (snapshot, cache) = try await MainActor.run {
                        (try store.ensureMLXAudioLink(model), store.hubCache)
                    }
                    try await engine.load(repo: model.repo, type: engineType, cache: cache)
                    await diarizer?.prepare()
                    onPreparing("")
                    log.info("Transcribing with \(model.id, privacy: .public) from \(snapshot.lastPathComponent, privacy: .public)")

                    let language = Self.languageHint(for: engineType, locale: locale)
                    let engine = engine
                    try await WindowedTranscription.run(
                        audio, sources: sources,
                        segmenter: Self.segmenterConfiguration(for: engineType),
                        diarizer: diarizer,
                        transcribe: { samples in try await engine.transcribe(samples, language: language) },
                        into: continuation)
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streaming engines are fast enough to refresh live words every second; Whisper decodes a
    /// 30-second window per call, so it refreshes less often and keeps utterances under that window.
    static func segmenterConfiguration(for engineType: String) -> UtteranceSegmenter.Configuration {
        var configuration = UtteranceSegmenter.Configuration()
        switch engineType {
        case "whisper":
            configuration.maxWindow = 28
            configuration.partialInterval = 2.5
        case "parakeet":
            configuration.maxWindow = 15
            configuration.partialInterval = 1.5
        default:
            break
        }
        return configuration
    }

    /// Whisper transcribes (instead of translating) only when told the language; the other engines
    /// detect it themselves.
    static func languageHint(for engineType: String, locale: Locale) -> String? {
        engineType == "whisper" ? locale.language.languageCode?.identifier : nil
    }
}

/// Owns the loaded mlx-audio model, which isn't thread-safe, and runs one transcription at a time.
actor STTEngine {
    private var model: (any STTGenerationModel)?

    func load(repo: String, type: String, cache: HubCache) async throws {
        guard model == nil else { return }
        // Offline: the store linked the pinned snapshot where mlx-audio looks for it.
        model = try await STT.loadModel(modelRepo: repo, modelType: type, cache: cache)
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let model else { throw LocalModelError.notDownloaded }
        try Task.checkCancellation()
        await InferenceGate.shared.acquire()
        let output = model.generate(
            audio: MLXArray(samples),
            generationParameters: STTGenerateParameters(language: language))
        await InferenceGate.shared.release()
        return output.text
    }
}
