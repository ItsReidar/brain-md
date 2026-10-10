//
//  ModelCatalog.swift
//  brain-md
//
//  Every model brain-md can download and run. Adding or swapping a model is one entry here:
//  the store downloads it, Settings lists it and the runtimes load it, all from the descriptor.
//

import Foundation

/// One downloadable MLX model.
nonisolated public struct ModelDescriptor: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Chat and note tasks. `vision` enables Explain Screen; `audio` lets the model transcribe speech.
        case language(vision: Bool, audio: Bool)
        /// Speech recognition through mlx-audio-swift. `engine` is the mlx-audio model type;
        /// `streaming` engines emit words while someone is still talking.
        case speech(engine: String, streaming: Bool)
        /// Tells speakers apart (Sortformer).
        case diarizer(maxSpeakers: Int)
    }

    /// Stable key stored in settings; never rename an existing one.
    public let id: String
    public let displayName: String
    public let summary: String
    /// Hugging Face repository.
    public let repo: String
    /// Pinned commit. swift-transformers still ships yyjson 0.12.0 (GHSA-f4vc-345x-4mvm), so only these
    /// known file sets are ever parsed. TODO: track `main` once huggingface/swift-transformers#392 ships.
    public let revision: String
    public let kind: Kind
    /// Total size of the repository's files, shown before downloading.
    public let approximateBytes: Int64
    public let license: String
    /// Stop strings some chat templates need besides the tokenizer's end-of-sequence token.
    public var extraEOSTokens: [String] = []
    /// False for base (pretrained) checkpoints: they continue text rather than follow instructions.
    public var isInstructionTuned = true
    /// A chat template bundled with the app (`Vendor/ChatTemplates/<name>.jinja`) for models whose
    /// tokenizer has none, such as base checkpoints.
    public var fallbackChatTemplate: String?
    public var downloadPatterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.vocab"]

    public var isLanguageModel: Bool { if case .language = kind { true } else { false } }
    public var isSpeechModel: Bool { if case .speech = kind { true } else { false } }
    public var isDiarizer: Bool { if case .diarizer = kind { true } else { false } }
    public var supportsVision: Bool { if case .language(let vision, _) = kind { vision } else { false } }
    public var supportsAudio: Bool { if case .language(_, let audio) = kind { audio } else { false } }

    /// What the model can do, shown as bubbles in Settings.
    public struct Capability: Hashable, Sendable {
        public let label: String
        /// SF Symbol.
        public let symbol: String

        public static let text = Capability(label: "Text", symbol: "text.alignleft")
        public static let images = Capability(label: "Images", symbol: "photo")
        public static let speech = Capability(label: "Speech", symbol: "waveform")
        public static let speechToText = Capability(label: "Speech to Text", symbol: "waveform")
        public static let live = Capability(label: "Live", symbol: "dot.radiowaves.left.and.right")
        public static let base = Capability(label: "Base", symbol: "square.stack.3d.down.right")
        public static func speakers(_ count: Int) -> Capability {
            Capability(label: "Up to \(count) speakers", symbol: "person.2.wave.2")
        }
    }

    /// Inputs first (text, images, speech), then qualifiers (live, base).
    public var capabilities: [Capability] {
        switch kind {
        case .language(let vision, let audio):
            [.text] + (vision ? [.images] : []) + (audio ? [.speech] : []) + (isInstructionTuned ? [] : [.base])
        case .speech(_, let streaming):
            [.speechToText] + (streaming ? [.live] : [])
        case .diarizer(let maxSpeakers):
            [.speakers(maxSpeakers)]
        }
    }
}

nonisolated public enum ModelCatalog {
    /// The model used until the user picks another; also the one brain-md 1.0–1.1 downloaded.
    public static let defaultLanguageModelID = "gemma-4-e4b-qat"

    public static let all: [ModelDescriptor] = language + speech + diarizers

    public static func model(_ id: ModelDescriptor.ID?) -> ModelDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    public static var languageModels: [ModelDescriptor] { language }
    public static var speechModels: [ModelDescriptor] { speech }

    // MARK: - Language models

    static let language: [ModelDescriptor] = [
        ModelDescriptor(
            id: "gemma-4-e4b-qat", displayName: "Gemma 4 E4B",
            summary: "Google · images and speech · balanced quality and speed",
            repo: "mlx-community/gemma-4-E4B-it-qat-4bit",
            revision: "0f35c6f6d386f7f74e628bd7c6526ce531212300",
            kind: .language(vision: true, audio: true), approximateBytes: 6_830_818_938,
            license: "Apache-2.0", extraEOSTokens: ["<turn|>"]),
        ModelDescriptor(
            id: "gemma-4-e4b-base", displayName: "Gemma 4 E4B Base",
            summary: "Google · images · not instruction-tuned: continues text, follows instructions loosely",
            repo: "mlx-community/gemma-4-e4b-4bit",
            revision: "1560521ede4c3196854c19b6a77fcc2db8d4e289",
            // Its checkpoint has the audio tower, but a base model doesn't reliably follow
            // "transcribe this", so meetings never fall back to it.
            kind: .language(vision: true, audio: false), approximateBytes: 5_249_794_027,
            license: "Apache-2.0", extraEOSTokens: ["<turn|>"],
            isInstructionTuned: false, fallbackChatTemplate: "gemma4"),
        ModelDescriptor(
            id: "gemma-4-e2b-base", displayName: "Gemma 4 E2B Base",
            summary: "Google · images · smallest Gemma, not instruction-tuned",
            repo: "mlx-community/gemma-4-e2b-4bit",
            revision: "a280baf4aece348bd0f561ca43b9d47cc66d8498",
            kind: .language(vision: true, audio: false), approximateBytes: 3_613_513_088,
            license: "Apache-2.0", extraEOSTokens: ["<turn|>"],
            isInstructionTuned: false, fallbackChatTemplate: "gemma4"),
        ModelDescriptor(
            id: "gemma-4-12b", displayName: "Gemma 4 12B",
            summary: "Google · images · highest quality, needs about 9 GB free",
            repo: "mlx-community/gemma-4-12B-it-4bit",
            revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
            // `gemma4_unified`: its audio path needs mlx-swift-lm#400, which isn't ported.
            kind: .language(vision: true, audio: false), approximateBytes: 6_773_372_848,
            license: "Apache-2.0", extraEOSTokens: ["<turn|>"]),
        ModelDescriptor(
            id: "qwen3.5-9b", displayName: "Qwen3.5 9B",
            summary: "Alibaba · images · strong reasoning",
            repo: "mlx-community/Qwen3.5-9B-MLX-4bit",
            revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631",
            kind: .language(vision: true, audio: false), approximateBytes: 5_977_074_591,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "qwen3.5-4b", displayName: "Qwen3.5 4B",
            summary: "Alibaba · images · fast",
            repo: "mlx-community/Qwen3.5-4B-MLX-4bit",
            revision: "32f3e8ecf65426fc3306969496342d504bfa13f3",
            kind: .language(vision: true, audio: false), approximateBytes: 3_061_132_920,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
            summary: "Alibaba · images · smallest and fastest",
            repo: "mlx-community/Qwen3.5-2B-MLX-4bit",
            revision: "93760be4f1f69842a46bc13dbdc0f19e291392a3",
            kind: .language(vision: true, audio: false), approximateBytes: 1_749_083_534,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "ministral-3-3b", displayName: "Ministral 3 3B",
            summary: "Mistral AI · images · compact",
            repo: "mlx-community/Ministral-3-3B-Instruct-2512-8bit",
            revision: "79ebb6ee5067d20a89765e54f43449cadccb66ff",
            kind: .language(vision: true, audio: false), approximateBytes: 4_501_963_529,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "mistral-7b-4bit", displayName: "Mistral 7B v0.3",
            summary: "Mistral AI · text only",
            repo: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            revision: "a4b8f870474b0eb527f466a03fbc187830d271f5",
            kind: .language(vision: false, audio: false), approximateBytes: 4_080_222_853,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "mistral-7b-8bit", displayName: "Mistral 7B v0.3 (8-bit)",
            summary: "Mistral AI · text only · higher precision",
            repo: "mlx-community/Mistral-7B-Instruct-v0.3-8bit",
            revision: "c282bcd11a64be44ac3f130f0b819d48ecc1846d",
            kind: .language(vision: false, audio: false), approximateBytes: 7_704_112_102,
            license: "Apache-2.0"),
    ]

    // MARK: - Speech recognition

    static let speech: [ModelDescriptor] = [
        ModelDescriptor(
            id: "nemotron-3.5-streaming-8bit", displayName: "Nemotron 3.5 Streaming",
            summary: "NVIDIA · live words as people speak · 25 languages incl. Dutch",
            repo: "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
            revision: "7279359e4481b5e9e185a318bd618e429c6d86cd",
            kind: .speech(engine: "nemotron_asr", streaming: true), approximateBytes: 756_247_988,
            license: "NVIDIA Open Model License"),
        ModelDescriptor(
            id: "nemotron-3.5-streaming", displayName: "Nemotron 3.5 Streaming (full precision)",
            summary: "NVIDIA · live words as people speak · slightly more accurate",
            repo: "mlx-community/nemotron-3.5-asr-streaming-0.6b",
            revision: "e550040c0478027ed679b2b6b0d055502c103663",
            kind: .speech(engine: "nemotron_asr", streaming: true), approximateBytes: 1_276_707_588,
            license: "NVIDIA Open Model License"),
        ModelDescriptor(
            id: "parakeet-tdt-v3", displayName: "Parakeet TDT v3",
            summary: "NVIDIA · very fast, sentence by sentence · 25 European languages",
            repo: "mlx-community/parakeet-tdt-0.6b-v3",
            revision: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
            kind: .speech(engine: "parakeet", streaming: false), approximateBytes: 2_509_044_141,
            license: "CC-BY-4.0"),
        ModelDescriptor(
            id: "orukeet", displayName: "Orukeet",
            summary: "Oruk AI · Parakeet v3 fine-tune, more accurate · sentence by sentence · 25 European languages",
            // Converted with scripts/models/convert_orukeet.py from oruk/orukeet@b59c13a7.
            repo: "itsreidar/orukeet-mlx",
            revision: "17894066e1d148997bfc93a4d41c605ca1b0475d",
            kind: .speech(engine: "parakeet", streaming: false), approximateBytes: 1_254_966_956,
            license: "CC-BY-SA-4.0"),
        ModelDescriptor(
            id: "voxtral-mini-realtime", displayName: "Voxtral Mini Realtime",
            summary: "Mistral AI · live words as people speak · 13 languages incl. Dutch",
            repo: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
            revision: "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e",
            kind: .speech(engine: "voxtral_realtime", streaming: true), approximateBytes: 3_148_833_321,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo",
            summary: "OpenAI · 99 languages · in 30-second blocks",
            repo: "mlx-community/whisper-large-v3-turbo-asr-fp16",
            revision: "624c19c9af5603fa73b83bce14d4aeea96156d18",
            kind: .speech(engine: "whisper", streaming: false), approximateBytes: 1_618_636_172,
            license: "MIT"),
        ModelDescriptor(
            id: "whisper-large-v3", displayName: "Whisper Large v3",
            summary: "OpenAI · 99 languages · most accurate Whisper, slowest",
            repo: "mlx-community/whisper-large-v3-asr-fp16",
            revision: "f4b9d561e7f1a5c0587726ff7ff03da2cc80fcf9",
            kind: .speech(engine: "whisper", streaming: false), approximateBytes: 3_087_749_956,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "whisper-small", displayName: "Whisper Small",
            summary: "OpenAI · 99 languages · light",
            repo: "mlx-community/whisper-small-asr-fp16",
            revision: "42fc41c2ab1c78e844fd01477cf398eec6801c47",
            kind: .speech(engine: "whisper", streaming: false), approximateBytes: 485_624_250,
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "whisper-base", displayName: "Whisper Base",
            summary: "OpenAI · 99 languages · smallest, lower accuracy",
            repo: "mlx-community/whisper-base-asr-fp16",
            revision: "52f819c9c5fa6874a2f14a97112951fc951aa253",
            kind: .speech(engine: "whisper", streaming: false), approximateBytes: 148_070_180,
            license: "Apache-2.0"),
    ]

    // MARK: - Speaker identification

    public static let defaultDiarizerID = "sortformer-4spk-v2.1"

    static let diarizers: [ModelDescriptor] = [
        ModelDescriptor(
            id: "sortformer-4spk-v2.1", displayName: "Sortformer (up to 4 speakers)",
            summary: "NVIDIA · labels who is talking on the call",
            repo: "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16",
            revision: "e23e6404bd9859e93edbf94a740eb1c7fc58f12e",
            kind: .diarizer(maxSpeakers: 4), approximateBytes: 236_114_032,
            license: "NVIDIA Open Model License"),
    ]
}
