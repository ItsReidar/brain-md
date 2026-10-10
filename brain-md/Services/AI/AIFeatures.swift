//
//  AIFeatures.swift
//  brain-md
//

import Foundation

/// The master switch for every AI feature (Settings › General › AI Features). Off makes brain-md a
/// plain notes app: no ✨ menu, skills, AI Chat, Explain Screen, meeting recording, model
/// downloads or Local AI & Voice settings. Nothing is deleted: downloaded models, skill files and
/// AI settings stay, and turning it back on restores everything as it was.
enum AIFeatures {
    /// On by default, so existing users keep their AI features.
    nonisolated static let key = "ai_features_enabled"

    nonisolated static func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Turns the features off and stops whatever is running: a meeting recording (its transcript so
    /// far stays in the note), model downloads, a chat answer, and the loaded model.
    static func turnOff(
        defaults: UserDefaults = .standard,
        recorder: MeetingRecorder = .shared,
        store: ModelStore = .shared,
        runtime: LanguageModelRuntime = .shared,
        chat: AssistantChat = .shared
    ) {
        defaults.set(false, forKey: key)
        recorder.stop()
        for model in ModelCatalog.all { store.cancelDownload(model) }
        chat.stop()
        runtime.unloadModel()
    }

    static func turnOn(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}
