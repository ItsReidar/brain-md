//
//  LanguageModelSpeechRecognizer.swift
//  brain-md
//

import Foundation
import MLX
import MLXLMCommon
import os

/// Transcribes meetings with the active language model when it can hear (Gemma 4 E4B) and no speech
/// model is installed. It reuses the model already in memory, so it costs no extra RAM, but it's
/// slower than a speech model: each passage appears once the speaker pauses.
nonisolated final class LanguageModelSpeechRecognizer: SpeechRecognizer {
    static let instruction = "Transcribe this audio verbatim in its original language. Output only the transcript."

    let model: ModelDescriptor
    private let runtime: LanguageModelRuntime
    private let diarizer: SpeakerDiarizer?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Transcription")

    init(model: ModelDescriptor, runtime: LanguageModelRuntime, diarizer: SpeakerDiarizer?) {
        self.model = model
        self.runtime = runtime
        self.diarizer = diarizer
    }

    /// Longer passages than a speech model, since every call has a fixed prompt cost; no live words.
    static var segmenterConfiguration: UtteranceSegmenter.Configuration {
        var configuration = UtteranceSegmenter.Configuration()
        configuration.maxWindow = 20
        configuration.silenceToCut = 0.8
        configuration.partialInterval = nil
        return configuration
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
                    onPreparing("Loading \(model.displayName)…")
                    let runtime = runtime
                    let model = model
                    let container = try await runtime.load(model)
                    await diarizer?.prepare()
                    onPreparing("")
                    log.info("Transcribing with \(model.id, privacy: .public) (language model audio)")

                    try await WindowedTranscription.run(
                        audio, sources: sources,
                        segmenter: Self.segmenterConfiguration,
                        diarizer: diarizer,
                        transcribe: { samples in try await Self.transcribe(samples, with: container) },
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

    /// One passage, in a fresh session so earlier passages don't fill the context.
    static func transcribe(_ samples: [Float], with container: ModelContainer) async throws -> String {
        try Task.checkCancellation()
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: 400, temperature: 0),
            processing: UserInput.Processing())
        await InferenceGate.shared.acquire()
        do {
            let text = try await session.respond(
                to: instruction, images: [], videos: [],
                audios: [UserInput.Audio(source: .array(MLXArray(samples)))])
            await InferenceGate.shared.release()
            return text
        } catch {
            await InferenceGate.shared.release()
            throw error
        }
    }
}
