//
//  SpeechEngine.swift
//  brain-md
//

import Foundation

/// Which engine transcribes meetings. Decided fresh for each recording, so installing or removing a
/// model takes effect on the next one.
nonisolated public enum SpeechEngine: Equatable, Sendable {
    /// A dedicated MLX speech-recognition model (fastest, live words for streaming engines).
    case speechModel(ModelDescriptor)
    /// The active language model listens to the audio itself (Gemma 4 E4B).
    case languageModel(ModelDescriptor)
    /// Apple's on-device SpeechAnalyzer, built into macOS; no download.
    case appleSpeech

    /// Order: the selected speech model if it's installed, then the active language model if it can
    /// hear and is installed, then Apple Speech. MLX engines need on-device AI turned on and Apple Silicon.
    public static func resolve(
        selectedSpeechModel: ModelDescriptor?,
        activeLanguageModel: ModelDescriptor,
        isAIEnabled: Bool,
        isSupportedHardware: Bool = ModelStore.isSupportedHardware,
        isInstalled: (ModelDescriptor) -> Bool
    ) -> SpeechEngine {
        guard isAIEnabled, isSupportedHardware else { return .appleSpeech }
        if let selectedSpeechModel, selectedSpeechModel.isSpeechModel, isInstalled(selectedSpeechModel) {
            return .speechModel(selectedSpeechModel)
        }
        if activeLanguageModel.supportsAudio, isInstalled(activeLanguageModel) {
            return .languageModel(activeLanguageModel)
        }
        return .appleSpeech
    }

    public var displayName: String {
        switch self {
        case .speechModel(let model), .languageModel(let model): model.displayName
        case .appleSpeech: "Apple Speech"
        }
    }

    /// One sentence for Settings: what meetings will use, and why.
    public var explanation: String {
        switch self {
        case .speechModel(let model):
            if case .speech(_, true) = model.kind {
                "Meetings use \(model.displayName): words appear while people speak."
            } else {
                "Meetings use \(model.displayName): each sentence appears when the speaker pauses."
            }
        case .languageModel(let model):
            "No speech model is installed, so \(model.displayName) listens to meetings itself. "
                + "It's slower than a speech model and shows each passage when it's finished."
        case .appleSpeech:
            "Meetings use Apple Speech, built into macOS. Install a speech model for faster, MLX-based transcription."
        }
    }
}
