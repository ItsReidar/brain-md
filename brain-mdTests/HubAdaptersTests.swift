//
//  HubAdaptersTests.swift
//  brain-mdTests
//

import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import brain_md

@MainActor
struct HubAdaptersTests {

    /// Stands in for Gemma 4's processor, which returns `input` with the given mask.
    private struct FakeProcessor: UserInputProcessor {
        let mask: MLXArray?
        let image: Bool

        func prepare(input: UserInput) async throws -> LMInput {
            let tokens = MLXArray([2, 105, 106]).expandedDimensions(axis: 0)
            return LMInput(
                text: .init(tokens: tokens, mask: mask),
                image: image ? LMInput.ProcessedImage(pixels: MLXArray.zeros([1, 3, 4, 4])) : nil)
        }
    }

    private func prepared(mask: MLXArray?, image: Bool = false) async throws -> LMInput {
        try await TextMaskDroppingProcessor(base: FakeProcessor(mask: mask, image: image))
            .prepare(input: UserInput(prompt: "Hi"))
    }

    @Test func allOnesMaskIsDroppedForTextSoTheCacheCanBeReused() async throws {
        let result = try await prepared(mask: MLXArray([1, 1, 1] as [Int8]).expandedDimensions(axis: 0))
        #expect(result.text.mask == nil)
        #expect(result.text.tokens.shape == [1, 3])
    }

    @Test func realMasksAndMediaPromptsAreKept() async throws {
        let padding = MLXArray([0, 1, 1] as [Int8]).expandedDimensions(axis: 0)
        #expect(try await prepared(mask: padding).text.mask != nil)

        let ones = MLXArray([1, 1, 1] as [Int8]).expandedDimensions(axis: 0)
        let withImage = try await prepared(mask: ones, image: true)
        #expect(withImage.text.mask != nil)
        #expect(withImage.image != nil)

        #expect(try await prepared(mask: nil).text.mask == nil)
    }

    /// Opt-in regression test: a follow-up turn must reuse the KV cache instead of re-reading the
    /// whole conversation (Gemma 4's processor used to attach a mask that disabled reuse).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func realModelFollowUpReusesTheCache() async throws {
        let session = ChatSession(
            try await LocalModelManager.shared.loadModel(), instructions: "Answer in one word.",
            generateParameters: GenerateParameters(maxTokens: 16, temperature: 0), processing: UserInput.Processing())
        var cached: [Int] = []
        for prompt in ["Name a colour.", "Name another one."] {
            for try await event in session.streamDetails(to: prompt) {
                if case .info(let info) = event { cached.append(info.cachedPromptTokenCount) }
            }
        }
        #expect(cached.count == 2)
        #expect(cached.last ?? 0 > 0, "turn 2 re-read the whole conversation")
        #expect(try await session.cacheStatus().processedTokenCount ?? 0 > 0)
    }
}
