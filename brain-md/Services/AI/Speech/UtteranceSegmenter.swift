//
//  UtteranceSegmenter.swift
//  brain-md
//

import Foundation

/// Cuts a live 16 kHz mono stream into utterances: a window opens when someone starts speaking and
/// closes after a pause (or at `maxWindow`). While a window is open it asks for partial
/// transcriptions every `partialInterval`, so words appear while people talk.
///
/// Speech is detected by energy against an adaptive noise floor, so no extra model is needed.
nonisolated struct UtteranceSegmenter {
    struct Configuration: Equatable {
        var sampleRate = 16_000
        /// Analysis frame (30 ms).
        var frameSamples = 480
        /// A pause this long ends the utterance.
        var silenceToCut: Double = 0.6
        /// Utterances are cut here even without a pause, so lines don't grow forever.
        var maxWindow: Double = 12
        /// Shorter bursts (clicks, coughs) are dropped.
        var minSpeech: Double = 0.25
        /// Audio kept from before speech starts, so the first syllable isn't clipped.
        var preRoll: Double = 0.25
        /// How often to re-transcribe the open window for live words; nil disables partials.
        var partialInterval: Double? = 1.0
        /// Speech must be this far above the noise floor (dB).
        var speechMargin: Float = 10
        /// Quietest level ever counted as speech (dBFS), for silent rooms.
        var absoluteFloor: Float = -50
    }

    enum Event: Equatable {
        /// The open utterance so far; `start` is seconds since the stream began.
        case partial(start: Double, samples: [Float])
        /// A finished utterance.
        case final(start: Double, samples: [Float])
    }

    let configuration: Configuration
    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var window: [Float] = []
    private var windowStartSample = 0
    private var processedSamples = 0
    private var inSpeech = false
    private var silentSamples = 0
    private var voicedSamples = 0
    private var samplesSincePartial = 0
    private var noiseFloor: Float = -60

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    private func samples(_ seconds: Double) -> Int { Int(seconds * Double(configuration.sampleRate)) }

    mutating func append(_ samples: [Float]) -> [Event] {
        pending.append(contentsOf: samples)
        var events: [Event] = []
        let frame = configuration.frameSamples
        var offset = 0
        while pending.count - offset >= frame {
            if let event = process(Array(pending[offset..<offset + frame])) { events.append(event) }
            offset += frame
        }
        pending.removeFirst(offset)
        return events
    }

    /// Ends the stream: the open utterance (if it holds enough speech) becomes final.
    mutating func flush() -> [Event] {
        if inSpeech, !pending.isEmpty { window.append(contentsOf: pending) }
        pending.removeAll()
        return closeWindow().map { [$0] } ?? []
    }

    private mutating func process(_ frame: [Float]) -> Event? {
        defer { processedSamples += frame.count }
        let level = Self.decibels(frame)
        let isLoud = level > max(noiseFloor + configuration.speechMargin, configuration.absoluteFloor)

        guard inSpeech else {
            if isLoud {
                inSpeech = true
                window = preRoll + frame
                windowStartSample = processedSamples - preRoll.count
                voicedSamples = frame.count
                silentSamples = 0
                samplesSincePartial = 0
                preRoll.removeAll()
            } else {
                noiseFloor = 0.95 * noiseFloor + 0.05 * level
                preRoll.append(contentsOf: frame)
                let keep = samples(configuration.preRoll)
                if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            }
            return nil
        }

        window.append(contentsOf: frame)
        samplesSincePartial += frame.count
        if isLoud {
            voicedSamples += frame.count
            silentSamples = 0
        } else {
            silentSamples += frame.count
        }

        if silentSamples >= samples(configuration.silenceToCut) {
            return closeWindow()
        }
        if window.count >= samples(configuration.maxWindow) {
            let event = closeWindow()
            // Still talking: the next window starts right away.
            inSpeech = true
            windowStartSample = processedSamples + frame.count
            return event
        }
        if let interval = configuration.partialInterval, samplesSincePartial >= samples(interval) {
            samplesSincePartial = 0
            return .partial(start: startSeconds, samples: window)
        }
        return nil
    }

    private var startSeconds: Double { Double(max(0, windowStartSample)) / Double(configuration.sampleRate) }

    private mutating func closeWindow() -> Event? {
        defer {
            inSpeech = false
            window.removeAll()
            voicedSamples = 0
            silentSamples = 0
            samplesSincePartial = 0
        }
        guard inSpeech, voicedSamples >= samples(configuration.minSpeech) else { return nil }
        return .final(start: startSeconds, samples: window)
    }

    /// RMS level in dBFS (−100 for silence).
    static func decibels(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -100 }
        let meanSquare = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        return meanSquare > 0 ? max(-100, 10 * log10(meanSquare)) : -100
    }
}
