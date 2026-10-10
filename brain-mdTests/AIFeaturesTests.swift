//
//  AIFeaturesTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

@MainActor
struct AIFeaturesTests {
    private func defaults() throws -> UserDefaults {
        let name = "brainmd-tests-ai-features-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func onByDefaultSoExistingUsersKeepTheirFeatures() throws {
        #expect(AIFeatures.isOn(try defaults()))
    }

    @Test func theMasterSwitchOverridesOnDeviceAI() throws {
        let defaults = try defaults()
        defaults.set(true, forKey: ModelSelection.enabledKey)
        #expect(ModelSelection.isOnDeviceAIEnabled(defaults))

        AIFeatures.turnOff(defaults: defaults, recorder: MeetingRecorder(defaults: defaults),
                           store: ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
                               .appendingPathComponent(UUID().uuidString)),
                           runtime: TestModels.isolatedRuntime(), chat: AssistantChat())
        #expect(!AIFeatures.isOn(defaults))
        #expect(!ModelSelection.isOnDeviceAIEnabled(defaults))
        // The on-device choice itself is kept, so turning the switch back on restores it.
        #expect(defaults.bool(forKey: ModelSelection.enabledKey))

        AIFeatures.turnOn(defaults: defaults)
        #expect(ModelSelection.isOnDeviceAIEnabled(defaults))
    }

    @Test func meetingsDontUseModelsWhileOff() throws {
        let defaults = try defaults()
        defaults.set(true, forKey: ModelSelection.enabledKey)
        defaults.set(false, forKey: AIFeatures.key)
        // Every model "installed", yet with AI features off meetings use Apple Speech.
        let engine = SpeechEngine.resolve(
            selectedSpeechModel: ModelCatalog.model("nemotron-3.5-streaming-8bit"),
            activeLanguageModel: ModelSelection.languageModel(defaults),
            isAIEnabled: ModelSelection.isOnDeviceAIEnabled(defaults),
            isSupportedHardware: true, isInstalled: { _ in true })
        #expect(engine == .appleSpeech)
    }

    @Test func turningOffStopsARecordingAndUnloadsTheModel() throws {
        let defaults = try defaults()
        let recorder = MeetingRecorder(defaults: defaults)
        let runtime = TestModels.isolatedRuntime()
        AIFeatures.turnOff(defaults: defaults, recorder: recorder, store: runtime.store, runtime: runtime,
                           chat: AssistantChat())
        #expect(!recorder.isRecording)
        #expect(runtime.loadedModel == nil)
    }
}
