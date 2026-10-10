//
//  SpeakerDiarizer.swift
//  brain-md
//

import Foundation
import MLX
import MLXAudioVAD
import os

/// Who spoke when on the call: turns from the diarizer, and the speaker for a transcript line.
nonisolated struct SpeakerTimeline: Equatable, Sendable {
    struct Turn: Equatable, Sendable {
        var start: Double
        var end: Double
        var speaker: Int
    }

    private(set) var turns: [Turn] = []

    mutating func add(_ newTurns: [Turn]) {
        turns.append(contentsOf: newTurns.filter { $0.end > $0.start })
    }

    /// The speaker with the most speech inside `start...end`, or nil when nobody overlaps it.
    /// Ties go to the lower index (the voice heard first).
    func speaker(from start: Double, to end: Double) -> Int? {
        var spoken: [Int: Double] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { spoken[turn.speaker, default: 0] += overlap }
        }
        return spoken.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }
}

/// Runs Sortformer over the call audio (16 kHz mono) as it arrives, so each final line can be
/// labelled "Speaker N". Failures turn identification off for the meeting instead of ending it.
actor SpeakerDiarizer {
    /// Audio is diarized in chunks this long: short enough to keep up, long enough to be efficient.
    static let chunkSeconds = 1.0

    let model: ModelDescriptor
    private let directory: @Sendable () async throws -> URL
    private var sortformer: SortformerModel?
    private var state: StreamingState?
    private var pending: [Float] = []
    private var timeline = SpeakerTimeline()
    private var failed = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Diarization")

    /// `directory` returns the downloaded snapshot; it's only called when the model is first needed.
    init(model: ModelDescriptor, directory: @escaping @Sendable () async throws -> URL) {
        self.model = model
        self.directory = directory
    }

    /// Loads the model ahead of the meeting's first words.
    func prepare() async {
        guard sortformer == nil, !failed else { return }
        do {
            let url = try await directory()
            let loaded = try SortformerModel.fromModelDirectory(url)
            sortformer = loaded
            state = loaded.initStreamingState()
            log.info("Loaded \(self.model.id, privacy: .public)")
        } catch {
            disable(error)
        }
    }

    func feed(_ samples: [Float]) async {
        guard !failed else { return }
        pending.append(contentsOf: samples)
        if Double(pending.count) >= Self.chunkSeconds * AudioResampler.sampleRate { await process() }
    }

    /// Diarizes what's left at the end of the meeting.
    func finish() async {
        await process()
    }

    /// The speaker for a transcript line spanning `start...end` seconds of call audio. Audio still
    /// waiting for a full chunk is diarized first if the line reaches into it.
    func speaker(from start: Double, to end: Double) async -> Int? {
        if Double(pending.count) >= 0.5 * AudioResampler.sampleRate { await process() }
        return timeline.speaker(from: start, to: end)
    }

    private func process() async {
        if sortformer == nil { await prepare() }
        guard let sortformer, let current = state, !pending.isEmpty, !failed else { return }
        let chunk = MLXArray(pending)
        pending.removeAll(keepingCapacity: true)
        await InferenceGate.shared.acquire()
        let output: DiarizationOutput
        do {
            let (result, next) = try await sortformer.feed(chunk: chunk, state: current)
            await InferenceGate.shared.release()
            output = result
            state = next
        } catch {
            await InferenceGate.shared.release()
            disable(error)
            return
        }
        timeline.add(output.segments.map {
            SpeakerTimeline.Turn(start: Double($0.start), end: Double($0.end), speaker: $0.speaker)
        })
    }

    private func disable(_ error: Error) {
        failed = true
        pending.removeAll()
        log.error("Speaker identification stopped: \(error.localizedDescription, privacy: .public)")
    }
}

/// MLX work from the speech model and the diarizer runs one at a time, so the two never compete
/// for the GPU mid-utterance and their results arrive in a predictable order.
actor InferenceGate {
    static let shared = InferenceGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the GPU; every `acquire` must be followed by one `release`.
    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
