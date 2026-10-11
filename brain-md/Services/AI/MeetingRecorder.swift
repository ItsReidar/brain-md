//
//  MeetingRecorder.swift
//  brain-md
//

import Combine
import Foundation

/// Runs one meeting recording: audio capture → on-device transcription → transcript lines.
/// Partial (volatile) text is published for a live overlay; only final lines reach the note.
public final class MeetingRecorder: ObservableObject {
    public static let shared = MeetingRecorder()

    @Published public private(set) var isRecording = false
    /// The current partial sentence per source, cleared once it becomes final.
    @Published public private(set) var liveText: [TranscriptionSegment.Speaker: String] = [:]
    @Published public private(set) var status: String?

    /// The engine the current (or last) recording used, for the overlay.
    @Published public private(set) var engine: SpeechEngine?

    private let capture: AudioCaptureService
    private let store: ModelStore
    private let runtime: LanguageModelRuntime
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    public init(
        capture: AudioCaptureService = .shared, store: ModelStore = .shared,
        runtime: LanguageModelRuntime = .shared, defaults: UserDefaults = .standard
    ) {
        self.capture = capture
        self.store = store
        self.runtime = runtime
        self.defaults = defaults
    }

    /// Picks the engine from what's installed right now: a speech model, else a language model that
    /// can hear, else Apple Speech.
    func resolveEngine() -> SpeechEngine {
        SpeechEngine.resolve(
            selectedSpeechModel: ModelSelection.speechModel(defaults),
            activeLanguageModel: ModelSelection.languageModel(defaults),
            isAIEnabled: ModelSelection.isOnDeviceAIEnabled(defaults),
            isInstalled: { self.store.isInstalled($0) })
    }

    /// Sortformer for call audio, when it's installed, turned on, and an MLX engine is transcribing.
    func makeDiarizer(for engine: SpeechEngine, capturesCall: Bool) -> SpeakerDiarizer? {
        guard capturesCall, engine != .appleSpeech, ModelSelection.identifiesSpeakers(defaults),
              let model = ModelCatalog.model(ModelCatalog.defaultDiarizerID), store.isInstalled(model)
        else { return nil }
        let store = store
        return SpeakerDiarizer(model: model) {
            try await MainActor.run { try store.ensureMLXAudioLink(model) }
        }
    }

    /// Starts recording. `onSegment` receives each final segment as it's recognized (write it with a
    /// `TranscriptWriter`); `onFinished` gets every final segment (for meeting minutes) and the error
    /// that ended it, if any.
    public func start(
        configuration: AudioCaptureConfiguration,
        locale: Locale,
        onSegment: @escaping (TranscriptionSegment) -> Void,
        onFinished: @escaping ([TranscriptionSegment], Error?) -> Void
    ) {
        guard !isRecording else { return }
        isRecording = true
        liveText = [:]
        status = "Starting…"
        capture.configuration = configuration

        task = Task {
            var segments: [TranscriptionSegment] = []
            var failure: Error?
            do {
                let audio = try await capture.start()
                status = nil
                var speakers: Set<TranscriptionSegment.Speaker> = []
                if configuration.captureSystemAudio { speakers.insert(.systemAudio) }
                if configuration.captureMicrophone { speakers.insert(.microphone) }
                let engine = resolveEngine()
                self.engine = engine
                let diarizer = makeDiarizer(for: engine, capturesCall: speakers.contains(.systemAudio))
                let recognizer = SpeechRecognizerFactory.make(
                    for: engine, store: store, runtime: runtime, diarizer: diarizer)
                let results = recognizer.transcribe(audio, locale: locale, sources: speakers) { message in
                    Task { @MainActor in self.status = message.isEmpty ? nil : message }
                }
                for try await segment in results {
                    if segment.isFinal {
                        liveText[segment.speaker] = nil
                        segments.append(segment)
                        status = nil
                        onSegment(segment)
                    } else {
                        liveText[segment.speaker] = segment.text
                    }
                }
            } catch {
                failure = error
            }
            await capture.stop()
            isRecording = false
            liveText = [:]
            status = nil
            task = nil
            onFinished(segments, failure)
        }
    }

    /// Stops capturing. Transcription finishes the audio already captured, then `onFinished` runs.
    public func stop() {
        guard isRecording else { return }
        status = "Finishing transcript…"
        Task { await capture.stop() }
    }

    /// One transcript line, e.g. `- **Speaker 2** [03:12] We slip two weeks.`
    static func line(for segment: TranscriptionSegment) -> String {
        let speaker = segment.speakerLabel
        let seconds = max(0, Int(segment.timestamp.rounded(.down)))
        let stamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return "- **\(speaker)** [\(stamp)] \(segment.text)"
    }
}
