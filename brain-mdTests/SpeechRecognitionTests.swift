//
//  SpeechRecognitionTests.swift
//  brain-mdTests
//

import AVFoundation
import Foundation
import Testing
@testable import brain_md

struct SpeechEngineTests {
    private let nemotron = ModelCatalog.model("nemotron-3.5-streaming-8bit")!
    private let gemma = ModelCatalog.model("gemma-4-e4b-qat")!
    private let qwen = ModelCatalog.model("qwen3.5-2b")!

    private func resolve(
        speech: ModelDescriptor?, language: ModelDescriptor, installed: Set<String>,
        enabled: Bool = true, hardware: Bool = true
    ) -> SpeechEngine {
        SpeechEngine.resolve(
            selectedSpeechModel: speech, activeLanguageModel: language, isAIEnabled: enabled,
            isSupportedHardware: hardware, isInstalled: { installed.contains($0.id) })
    }

    @Test func installedSpeechModelWins() {
        #expect(resolve(speech: nemotron, language: gemma, installed: [nemotron.id, gemma.id]) == .speechModel(nemotron))
    }

    @Test func audioCapableLanguageModelIsTheFallback() {
        #expect(resolve(speech: nemotron, language: gemma, installed: [gemma.id]) == .languageModel(gemma))
        #expect(resolve(speech: nil, language: gemma, installed: [gemma.id]) == .languageModel(gemma))
    }

    @Test func textOnlyLanguageModelFallsBackToAppleSpeech() {
        #expect(resolve(speech: nil, language: qwen, installed: [qwen.id, gemma.id]) == .appleSpeech)
    }

    @Test func nothingInstalledUsesAppleSpeech() {
        #expect(resolve(speech: nemotron, language: gemma, installed: []) == .appleSpeech)
    }

    @Test func disabledAIOrIntelUsesAppleSpeech() {
        let all: Set = [nemotron.id, gemma.id]
        #expect(resolve(speech: nemotron, language: gemma, installed: all, enabled: false) == .appleSpeech)
        #expect(resolve(speech: nemotron, language: gemma, installed: all, hardware: false) == .appleSpeech)
    }

    @Test func aLanguageModelIsNeverUsedAsTheSpeechModel() {
        #expect(resolve(speech: gemma, language: qwen, installed: [gemma.id, qwen.id]) == .appleSpeech)
    }
}

struct ModelCatalogTests {
    @Test func entriesAreUniqueAndPinned() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ModelCatalog.all.map(\.repo)).count == ids.count)
        for model in ModelCatalog.all {
            #expect(model.revision.count == 40 && model.revision.allSatisfy(\.isHexDigit), "\(model.id)")
            #expect(model.repo.split(separator: "/").count == 2, "\(model.id)")
            #expect(model.approximateBytes > 0, "\(model.id)")
            #expect(!model.license.isEmpty, "\(model.id)")
        }
    }

    @Test func defaultsExistWithTheRightKinds() throws {
        #expect(try #require(ModelCatalog.model(ModelCatalog.defaultLanguageModelID)).isLanguageModel)
        #expect(try #require(ModelCatalog.model(ModelCatalog.defaultDiarizerID)).isDiarizer)
    }

    @Test func speechEnginesAreOnesMLXAudioLoads() {
        let supported: Set = ["parakeet", "nemotron_asr", "whisper", "voxtral_realtime"]
        for model in ModelCatalog.speechModels {
            guard case .speech(let engine, _) = model.kind else { continue }
            #expect(supported.contains(engine), "\(model.id): \(engine)")
        }
    }

    @Test func baseModelsShipABundledChatTemplate() throws {
        let base = ModelCatalog.languageModels.filter { !$0.isInstructionTuned }
        #expect(Set(base.map(\.id)) == ["gemma-4-e4b-base", "gemma-4-e2b-base"])
        for model in base {
            let name = try #require(model.fallbackChatTemplate, "\(model.id)")
            let template = try #require(ChatTemplates.template(named: name), "\(name).jinja isn't in the app bundle")
            #expect(template.contains("<|turn>") && template.contains("bos_token"))
        }
        // Base models never transcribe meetings, even though their checkpoints include the audio tower.
        #expect(base.allSatisfy { !$0.supportsAudio })
    }

    @Test func onlyGemma4E4BHearsAudio() {
        #expect(ModelCatalog.languageModels.filter(\.supportsAudio).map(\.id) == ["gemma-4-e4b-qat"])
    }
}

struct UtteranceSegmenterTests {
    private let rate = 16_000

    private func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * 220 * Float($0) / Float(rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        // A faint hiss, like a real room, so the noise floor has something to learn.
        (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -0.0005...0.0005) }
    }

    private func finals(_ events: [UtteranceSegmenter.Event]) -> [(start: Double, seconds: Double)] {
        events.compactMap {
            if case .final(let start, let samples) = $0 { (start, Double(samples.count) / 16_000) } else { nil }
        }
    }

    @Test func speechBetweenPausesBecomesOneUtterance() throws {
        var segmenter = UtteranceSegmenter()
        let events = segmenter.append(silence(1) + tone(2) + silence(1))
        let utterance = try #require(finals(events).first)
        #expect(finals(events).count == 1)
        // Starts just before the speech (pre-roll) and ends after the pause that closed it.
        #expect(abs(utterance.start - 0.75) < 0.05)
        #expect(utterance.seconds > 2.5 && utterance.seconds < 3)
    }

    @Test func partialsArriveWhileSpeaking() {
        var segmenter = UtteranceSegmenter()
        let events = segmenter.append(silence(0.5) + tone(3.5))
        let partials = events.filter { if case .partial = $0 { true } else { false } }
        #expect(partials.count == 3)
        #expect(finals(events).isEmpty)
    }

    @Test func partialsCanBeTurnedOff() {
        var configuration = UtteranceSegmenter.Configuration()
        configuration.partialInterval = nil
        var segmenter = UtteranceSegmenter(configuration: configuration)
        #expect(segmenter.append(silence(0.5) + tone(3)).isEmpty)
    }

    @Test func longSpeechIsCutAtMaxWindow() {
        var configuration = UtteranceSegmenter.Configuration()
        configuration.maxWindow = 4
        configuration.partialInterval = nil
        var segmenter = UtteranceSegmenter(configuration: configuration)
        let events = segmenter.append(silence(0.5) + tone(9)) + segmenter.flush()
        let cuts = finals(events)
        #expect(cuts.count == 3)
        #expect(cuts.allSatisfy { $0.seconds <= 4.03 }) // within one 30 ms frame
        // Back to back: each window starts where the previous one ended.
        #expect(abs(cuts[1].start - (cuts[0].start + cuts[0].seconds)) < 0.05)
    }

    @Test func clicksAreDropped() {
        var segmenter = UtteranceSegmenter()
        #expect(finals(segmenter.append(silence(1) + tone(0.1) + silence(1))).isEmpty)
    }

    @Test func flushEmitsTheOpenUtterance() {
        var segmenter = UtteranceSegmenter()
        _ = segmenter.append(silence(0.5) + tone(1))
        #expect(finals(segmenter.flush()).count == 1)
        #expect(segmenter.flush().isEmpty)
    }

    @Test func chunkSizeDoesNotChangeTheResult() {
        let audio = silence(1) + tone(2) + silence(1) + tone(1.5) + silence(1)
        var whole = UtteranceSegmenter()
        let expected = finals(whole.append(audio)).map(\.start)
        var chunked = UtteranceSegmenter()
        var events: [UtteranceSegmenter.Event] = []
        for start in stride(from: 0, to: audio.count, by: 1_234) {
            events += chunked.append(Array(audio[start..<min(start + 1_234, audio.count)]))
        }
        #expect(finals(events).map(\.start) == expected)
        #expect(expected.count == 2)
    }
}

struct SpeakerTimelineTests {
    @Test func picksTheSpeakerWithTheMostOverlap() {
        var timeline = SpeakerTimeline()
        timeline.add([.init(start: 0, end: 4, speaker: 0), .init(start: 4, end: 10, speaker: 1)])
        #expect(timeline.speaker(from: 1, to: 3) == 0)
        #expect(timeline.speaker(from: 3, to: 9) == 1)
        #expect(timeline.speaker(from: 2, to: 6) == 0) // 2 s each: the earlier voice wins the tie
    }

    @Test func sumsSplitTurns() {
        var timeline = SpeakerTimeline()
        // Speaker 1 talks in two pieces that together outweigh speaker 0's single piece.
        timeline.add([
            .init(start: 0, end: 1.5, speaker: 1), .init(start: 1.5, end: 3.5, speaker: 0),
            .init(start: 3.5, end: 5, speaker: 1),
        ])
        #expect(timeline.speaker(from: 0, to: 5) == 1)
    }

    @Test func nobodyWhenNothingOverlaps() {
        var timeline = SpeakerTimeline()
        #expect(timeline.speaker(from: 0, to: 1) == nil)
        timeline.add([.init(start: 5, end: 6, speaker: 2), .init(start: 7, end: 7, speaker: 3)])
        #expect(timeline.speaker(from: 0, to: 5) == nil)
        #expect(timeline.turns.count == 1)
    }
}

@MainActor
struct SpeakerLabelTests {
    @Test func labels() {
        #expect(TranscriptionSegment(speaker: .microphone).speakerLabel == "Me")
        #expect(TranscriptionSegment(speaker: .microphone, speakerIndex: 2).speakerLabel == "Me")
        #expect(TranscriptionSegment(speaker: .systemAudio).speakerLabel == "Them")
        #expect(TranscriptionSegment(speaker: .systemAudio, speakerIndex: 1).speakerLabel == "Speaker 2")
    }

    @Test func noteLineUsesTheIdentifiedSpeaker() {
        #expect(MeetingRecorder.line(for: TranscriptionSegment(
            speaker: .systemAudio, speakerIndex: 1, timestamp: 192.7, text: "We slip two weeks."))
            == "- **Speaker 2** [03:12] We slip two weeks.")
    }

    @Test func minutesPromptUsesSpeakerLabels() throws {
        let prompt = try LanguageModelService.prompt(for: RewriteRequest(mode: .summarizeMeeting, transcripts: [
            TranscriptionSegment(speaker: .systemAudio, speakerIndex: 0, text: "Launch slips.", isFinal: true),
            TranscriptionSegment(speaker: .microphone, text: "Agreed.", isFinal: true),
        ]))
        #expect(prompt.contains("Speaker 1: Launch slips."))
        #expect(prompt.contains("Me: Agreed."))
    }

    @Test func engineSettingsPerModel() {
        #expect(MLXSpeechRecognizer.segmenterConfiguration(for: "whisper").maxWindow < 30)
        #expect(MLXSpeechRecognizer.segmenterConfiguration(for: "nemotron_asr").partialInterval == 1)
        #expect(MLXSpeechRecognizer.languageHint(for: "whisper", locale: Locale(identifier: "nl_BE")) == "nl")
        #expect(MLXSpeechRecognizer.languageHint(for: "parakeet", locale: Locale(identifier: "nl_BE")) == nil)
        #expect(LanguageModelSpeechRecognizer.segmenterConfiguration.partialInterval == nil)
    }

    @Test func diarizerOnlyRunsForMLXEnginesOnCallAudio() throws {
        let defaults = try #require(UserDefaults(suiteName: "brainmd-tests-diarizer"))
        defaults.removePersistentDomain(forName: "brainmd-tests-diarizer")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recorder = MeetingRecorder(store: ModelStore(modelsDirectory: directory), defaults: defaults)
        let gemma = try #require(ModelCatalog.model("gemma-4-e4b-qat"))
        // Sortformer isn't downloaded in this empty store.
        #expect(recorder.makeDiarizer(for: .languageModel(gemma), capturesCall: true) == nil)
        #expect(recorder.makeDiarizer(for: .appleSpeech, capturesCall: true) == nil)
        #expect(recorder.resolveEngine() == .appleSpeech)
    }
}
