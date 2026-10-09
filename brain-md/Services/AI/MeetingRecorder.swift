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

    private let capture: AudioCaptureService
    private let transcriber = MeetingTranscriber()
    private var task: Task<Void, Never>?

    public init(capture: AudioCaptureService = .shared) {
        self.capture = capture
    }

    /// Starts recording. `onLine` receives each final transcript line as Markdown; `onFinished`
    /// gets every final segment (for meeting minutes) and the error that ended it, if any.
    public func start(
        configuration: AudioCaptureConfiguration,
        locale: Locale,
        onLine: @escaping (String) -> Void,
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
                let results = transcriber.transcribe(audio, locale: locale, speakers: speakers) { message in
                    Task { @MainActor in self.status = message }
                }
                for try await segment in results {
                    if segment.isFinal {
                        liveText[segment.speaker] = nil
                        segments.append(segment)
                        status = nil
                        onLine(Self.line(for: segment))
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

    /// One transcript line, e.g. `- **Them** [03:12] We slip two weeks.`
    static func line(for segment: TranscriptionSegment) -> String {
        let speaker = segment.speaker == .microphone ? "Me" : "Them"
        let seconds = max(0, Int(segment.timestamp.rounded(.down)))
        let stamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return "- **\(speaker)** [\(stamp)] \(segment.text)"
    }
}
