//
//  EmbeddingRuntime.swift
//  brain-md
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import os

/// Whether a text is the search query or a note being indexed; models prefix them differently.
nonisolated enum EmbeddingRole: Sendable {
    case query, document
}

/// Turns texts into L2-normalised vectors. The index only needs this, so tests can fake it.
nonisolated protocol TextEmbedder: Sendable {
    var modelID: String { get }
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]]
}

/// The selected embedding model, run on this Mac.
nonisolated struct LocalEmbedder: TextEmbedder {
    let model: ModelDescriptor
    let directory: URL
    var modelID: String { model.id }

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        try await EmbeddingRuntime.shared.embed(texts, as: role, model: model, directory: directory)
    }
}

/// Loads an MLX embedding model on first use and unloads it after a few idle minutes, so nothing
/// stays in memory between searches.
actor EmbeddingRuntime {
    static let shared = EmbeddingRuntime()

    /// Longer inputs are cut; notes are chunked well below this.
    static let maxTokens = 512
    static let batchSize = 16
    static let idleUnloadDelay: Duration = .seconds(180)

    private enum Encoder {
        /// The vendored EmbeddingGemma pools, projects and normalises itself.
        case gemma(BrainEmbeddingGemma)
        case package(any EmbeddingModel, Pooling)
    }

    private var loaded: (model: ModelDescriptor, encoder: Encoder, tokenizer: any MLXLMCommon.Tokenizer)?
    private var idleUnload: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Embedding")

    var loadedModelID: String? { loaded?.model.id }

    func embed(_ texts: [String], as role: EmbeddingRole, model: ModelDescriptor, directory: URL) async throws
        -> [[Float]]
    {
        guard case .embedding(_, let queryPrefix, let documentPrefix, _) = model.kind else {
            throw LocalModelError.unknownModel(model.id)
        }
        idleUnload?.cancel()
        defer { scheduleIdleUnload() }
        let (encoder, tokenizer) = try await load(model, from: directory)
        let prefix = role == .query ? queryPrefix : documentPrefix

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            let batch = texts[start..<min(start + Self.batchSize, texts.count)].map { prefix + $0 }
            await InferenceGate.shared.acquire()
            let pooled = Self.run(encoder, tokenizer: tokenizer, batch: batch)
            await InferenceGate.shared.release()
            vectors += (0..<pooled.dim(0)).map { pooled[$0].asArray(Float.self) }
        }
        return vectors
    }

    func unload() {
        idleUnload?.cancel()
        guard let model = loaded?.model else { return }
        loaded = nil
        MLX.Memory.clearCache()
        log.info("Unloaded \(model.id, privacy: .public)")
    }

    private func scheduleIdleUnload() {
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func load(_ model: ModelDescriptor, from directory: URL) async throws
        -> (Encoder, any MLXLMCommon.Tokenizer)
    {
        if let loaded, loaded.model == model { return (loaded.encoder, loaded.tokenizer) }
        unload()
        guard ModelStore.isSupportedHardware else { throw LocalModelError.requiresAppleSilicon }
        guard case .embedding(let pooling, _, _, _) = model.kind else { throw LocalModelError.unknownModel(model.id) }

        let required = Int64(Double(model.approximateBytes) * LanguageModelRuntime.memoryHeadroom)
        let available = ModelStore.availableMemoryBytes()
        guard available >= required else {
            throw LocalModelError.insufficientMemory(requiredBytes: required, availableBytes: available)
        }

        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let encoder: Encoder
        let module: any BaseLanguageModel
        switch pooling {
        case .model:
            let gemma = BrainEmbeddingGemma(
                try JSONDecoder().decode(BrainGemma3EmbeddingConfiguration.self, from: configData))
            encoder = .gemma(gemma)
            module = gemma
        case .mean, .cls, .last:
            let model = try await EmbedderTypeRegistry.shared.createModel(
                configuration: configData, modelType: base.modelType)
            let strategy: Pooling.Strategy = switch pooling {
            case .cls: .cls
            case .last: .last
            default: .mean
            }
            encoder = .package(model, Pooling(strategy: strategy))
            module = model
        }
        try await loadWeights(modelDirectory: directory, model: module, perLayerQuantization: base.perLayerQuantization)
        let tokenizer = try await TransformersTokenizerLoader().load(from: directory)
        loaded = (model, encoder, tokenizer)
        log.info("Loaded \(model.id, privacy: .public)")
        return (encoder, tokenizer)
    }

    /// Tokenises, right-pads (last-token pooling needs it), runs and pools one batch.
    private static func run(_ encoder: Encoder, tokenizer: any MLXLMCommon.Tokenizer, batch: [String]) -> MLXArray {
        let tokens = batch.map { truncated(tokenizer.encode(text: $0, addSpecialTokens: true)) }
        let length = max(1, tokens.map(\.count).max() ?? 1)
        let ids = MLXArray(tokens.flatMap { $0.map(Int32.init) + Array(repeating: 0, count: length - $0.count) })
            .reshaped(tokens.count, length)
        let mask = MLXArray(tokens.flatMap { Array(repeating: Int32(1), count: $0.count) + Array(repeating: 0, count: length - $0.count) })
            .reshaped(tokens.count, length)
        let pooled: MLXArray = switch encoder {
        case .gemma(let model):
            model(ids, positionIds: nil, tokenTypeIds: nil, attentionMask: mask).pooledOutput!
        case .package(let model, let pooling):
            pooling(
                model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids), attentionMask: mask),
                mask: mask, normalize: true)
        }
        let result = pooled.asType(.float32)
        eval(result)
        return result
    }

    /// Cuts to `maxTokens`, keeping the closing special token (last-token pooling reads it).
    static func truncated(_ tokens: [Int]) -> [Int] {
        guard tokens.count > maxTokens, let last = tokens.last else { return tokens }
        return Array(tokens.prefix(maxTokens - 1)) + [last]
    }
}
