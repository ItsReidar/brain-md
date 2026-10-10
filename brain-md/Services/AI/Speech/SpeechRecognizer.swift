//
//  SpeechRecognizer.swift
//  brain-md
//

@preconcurrency import AVFoundation
import Foundation

/// Turns captured meeting audio into transcript segments. Each engine (Apple Speech, an MLX speech
/// model, an audio-capable language model) implements this, so the recorder doesn't care which runs.
nonisolated public protocol SpeechRecognizer: Sendable {
    /// Transcribes `audio` until it finishes, streaming partial and final segments per source.
    /// `onPreparing` reports one-time setup such as loading or installing a model.
    func transcribe(
        _ audio: AsyncStream<CapturedAudio>,
        locale: Locale,
        sources: Set<TranscriptionSegment.Speaker>,
        onPreparing: @escaping @Sendable (String) -> Void
    ) -> AsyncThrowingStream<TranscriptionSegment, Error>
}

/// Builds the recognizer for the engine `SpeechEngine.resolve` picked.
@MainActor
enum SpeechRecognizerFactory {
    static func make(
        for engine: SpeechEngine,
        store: ModelStore,
        runtime: LanguageModelRuntime,
        diarizer: SpeakerDiarizer? = nil
    ) -> any SpeechRecognizer {
        switch engine {
        case .speechModel(let model):
            MLXSpeechRecognizer(model: model, store: store, diarizer: diarizer)
        case .languageModel(let model):
            LanguageModelSpeechRecognizer(model: model, runtime: runtime, diarizer: diarizer)
        case .appleSpeech:
            AppleSpeechRecognizer()
        }
    }
}

/// Converts capture buffers (any rate, any channel count) to 16 kHz mono Float32 samples.
nonisolated final class AudioResampler: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    private let target = AVAudioFormat(standardFormatWithSampleRate: AudioResampler.sampleRate, channels: 1)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
