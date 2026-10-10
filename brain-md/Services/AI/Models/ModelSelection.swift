//
//  ModelSelection.swift
//  brain-md
//

import Foundation

/// The user's model choices, stored in user defaults so `@AppStorage` views and services agree.
nonisolated public enum ModelSelection {
    /// "Enable on-device AI" (kept from 1.0 so existing users stay enabled).
    public static let enabledKey = "ai_on_device_enabled"
    public static let languageModelKey = "ai_language_model"
    /// Empty means no ASR model: speech falls back to the language model or Apple Speech.
    public static let speechModelKey = "ai_speech_model"
    public static let identifySpeakersKey = "ai_identify_speakers"

    public static func languageModel(_ defaults: UserDefaults = .standard) -> ModelDescriptor {
        ModelCatalog.model(defaults.string(forKey: languageModelKey)).flatMap { $0.isLanguageModel ? $0 : nil }
            ?? ModelCatalog.model(ModelCatalog.defaultLanguageModelID)!
    }

    public static func speechModel(_ defaults: UserDefaults = .standard) -> ModelDescriptor? {
        ModelCatalog.model(defaults.string(forKey: speechModelKey)).flatMap { $0.isSpeechModel ? $0 : nil }
    }

    public static func identifiesSpeakers(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: identifySpeakersKey) as? Bool ?? true
    }
}
