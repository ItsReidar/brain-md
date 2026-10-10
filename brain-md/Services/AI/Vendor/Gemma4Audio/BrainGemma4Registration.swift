//
//  BrainGemma4Registration.swift
//  brain-md
//
//  Gemma 4 with audio input, ported from ml-explore/mlx-swift-lm PR #392
//  (https://github.com/ml-explore/mlx-swift-lm/pull/392, head 6abe0898, by fdagostino; MIT License,
//  Copyright © 2024-2026 Apple Inc. and contributors). mlx-swift-lm 3.32.3 drops Gemma 4's
//  `audio_tower` weights; this copy keeps them so Gemma 4 can transcribe speech.
//  TODO: remove this folder once an mlx-swift-lm release ships Gemma 4 audio input.
//

import Foundation
import MLXLMCommon
import MLXVLM

/// Replaces mlx-swift-lm's `gemma4` model and `Gemma4Processor` with the audio-capable copies.
nonisolated enum BrainGemma4Registration {
    private static let once = Once()

    /// Idempotent; call before loading any model.
    static func register() async {
        guard await once.claim() else { return }
        await VLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let configuration = try JSONDecoder.json5().decode(BrainGemma4Configuration.self, from: data)
            return BrainGemma4(configuration)
        }
        await VLMProcessorTypeRegistry.shared.registerProcessorType("Gemma4Processor") { data, tokenizer in
            let configuration = try JSONDecoder.json5().decode(BrainGemma4ProcessorConfiguration.self, from: data)
            return BrainGemma4Processor(configuration, tokenizer: tokenizer)
        }
    }

    private actor Once {
        private var done = false
        func claim() -> Bool {
            defer { done = true }
            return !done
        }
    }
}
