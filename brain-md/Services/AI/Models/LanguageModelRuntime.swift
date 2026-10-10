//
//  LanguageModelRuntime.swift
//  brain-md
//

import Combine
import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import os

/// Loads and unloads the active language model (the one picked in Settings). One model is in
/// memory at a time; switching models unloads the previous one.
public final class LanguageModelRuntime: ObservableObject {
    public static let shared = LanguageModelRuntime(store: .shared)

    /// Weights plus KV cache and activations: loading needs this much headroom over the file size.
    nonisolated static let memoryHeadroom = 1.2

    @Published public private(set) var loadedModel: ModelDescriptor?
    public var isLoaded: Bool { loadedModel != nil }
    /// The loaded model's context length, from its config.
    public private(set) var contextWindow: Int?

    public let store: ModelStore
    private let defaults: UserDefaults
    private var container: ModelContainer?
    private var loadTask: (model: ModelDescriptor, task: Task<ModelContainer, Error>)?
    private var storeObserver: AnyCancellable?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "LanguageModel")

    public init(store: ModelStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // Re-publish store changes so views observing the runtime see download progress too.
        storeObserver = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// The model picked in Settings.
    public var activeModel: ModelDescriptor { ModelSelection.languageModel(defaults) }

    public var isActiveModelInstalled: Bool { store.isInstalled(activeModel) }

    /// Loads the active model from disk (offline), or returns it if it's already loaded.
    public func loadModel() async throws -> ModelContainer {
        try await load(activeModel)
    }

    public func load(_ model: ModelDescriptor) async throws -> ModelContainer {
        guard ModelStore.isSupportedHardware else { throw LocalModelError.requiresAppleSilicon }
        guard model.isLanguageModel else { throw LocalModelError.unknownModel(model.id) }
        if let container, loadedModel == model { return container }
        if let loadTask, loadTask.model == model { return try await loadTask.task.value }
        if loadedModel != nil { unloadModel() }
        guard let directory = store.snapshotDirectory(of: model) else { throw LocalModelError.notDownloaded }

        let required = Int64(Double(store.diskUsageBytes(of: model)) * Self.memoryHeadroom)
        let available = ModelStore.availableMemoryBytes()
        guard available >= required else {
            throw LocalModelError.insufficientMemory(requiredBytes: required, availableBytes: available)
        }

        let configuration = ModelConfiguration(
            directory: directory, defaultPrompt: "Describe the image in English",
            extraEOSTokens: Set(model.extraEOSTokens))
        let downloader = HubDownloader(client: HubClient(cache: store.hubCache))
        let task = Task {
            var context = try await Self.loadContext(configuration, downloader: downloader)
            context.processor = TextMaskDroppingProcessor(base: context.processor)
            return ModelContainer(context: context)
        }
        loadTask = (model, task)
        defer { if loadTask?.model == model { loadTask = nil } }
        let loaded = try await task.value
        container = loaded
        loadedModel = model
        contextWindow = Self.contextWindow(inConfigAt: directory)
        log.info("Loaded \(model.id, privacy: .public)")
        return loaded
    }

    /// Vision-capable architectures load through the VLM factory, text-only ones (Mistral) through
    /// the LLM factory. Gemma 4's audio-capable copy is registered first.
    nonisolated static func loadContext(
        _ configuration: ModelConfiguration, downloader: some Downloader
    ) async throws -> ModelContext {
        await BrainGemma4Registration.register()
        do {
            return try await VLMModelFactory.shared.load(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
        } catch ModelFactoryError.unsupportedModelType {
            return try await LLMModelFactory.shared.load(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
        }
    }

    /// `max_position_embeddings` from `config.json`, at the top level or in `text_config` (multimodal models).
    nonisolated static func contextWindow(inConfigAt directory: URL) -> Int? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let text = config["text_config"] as? [String: Any]
        return (text?["max_position_embeddings"] as? Int) ?? (config["max_position_embeddings"] as? Int)
    }

    public func unloadModel() {
        loadTask?.task.cancel()
        loadTask = nil
        container = nil
        contextWindow = nil
        guard let model = loadedModel else { return }
        loadedModel = nil
        MLX.Memory.clearCache()
        log.info("Unloaded \(model.id, privacy: .public)")
    }

    /// Deletes a model's files, unloading it first if it's in memory.
    public func remove(_ model: ModelDescriptor) {
        if loadedModel == model || loadTask?.model == model { unloadModel() }
        store.remove(model)
    }
}
