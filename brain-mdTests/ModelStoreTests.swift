//
//  ModelStoreTests.swift
//  brain-mdTests
//

import Foundation
import MLXLMCommon
import Testing
@testable import brain_md

@MainActor
struct ModelStoreTests {

    static let gemma = ModelCatalog.model(ModelCatalog.defaultLanguageModelID)!

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in directory: URL, contents: String = "{}") throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test func onlyAppleSiliconLoadsTheModel() {
        #if arch(arm64)
        #expect(ModelStore.isSupportedHardware)
        #else
        #expect(!ModelStore.isSupportedHardware)
        #endif
        #expect(LocalModelError.requiresAppleSilicon.errorDescription?.contains("Apple Silicon") == true)
    }

    @Test func snapshotRequiresEveryIndexedWeightFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("config.json", in: directory)
        try write("tokenizer.json", in: directory)
        try write("model.safetensors.index.json", in: directory, contents: """
            {"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}
            """)
        try write("model-00001-of-00002.safetensors", in: directory, contents: "x")
        #expect(!ModelStore.snapshotIsComplete(directory, for: Self.gemma))

        try write("model-00002-of-00002.safetensors", in: directory, contents: "x")
        #expect(ModelStore.snapshotIsComplete(directory, for: Self.gemma))
    }

    @Test func snapshotWithoutConfigOrTokenizerIsIncomplete() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("model.safetensors", in: directory, contents: "x")
        #expect(!ModelStore.snapshotIsComplete(directory, for: Self.gemma))

        try write("config.json", in: directory)
        #expect(!ModelStore.snapshotIsComplete(directory, for: Self.gemma)) // language models need a tokenizer
        try write("tokenizer.json", in: directory)
        #expect(ModelStore.snapshotIsComplete(directory, for: Self.gemma))
    }

    /// Speech models ship their own tokenizer formats (or none): config plus weights is enough.
    @Test func speechSnapshotNeedsConfigAndWeightsOnly() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parakeet = try #require(ModelCatalog.model("parakeet-tdt-v3"))
        try write("config.json", in: directory)
        #expect(!ModelStore.snapshotIsComplete(directory, for: parakeet))
        try write("model.safetensors", in: directory, contents: "x")
        #expect(ModelStore.snapshotIsComplete(directory, for: parakeet))
    }

    /// mlx-audio-swift finds speech models at `<cache>/mlx-audio/<org>_<name>`; the store links the
    /// pinned snapshot there so they load offline at the pinned revision.
    @Test func speechModelsAreLinkedWhereMLXAudioLooks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ModelStore(modelsDirectory: directory)
        let nemotron = try #require(ModelCatalog.model("nemotron-3.5-streaming-8bit"))
        let snapshot = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: snapshot) }

        try store.linkForMLXAudio(nemotron, snapshot: snapshot)
        let link = directory.appendingPathComponent("mlx-audio/mlx-community_nemotron-3.5-asr-streaming-0.6b-8bit")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == snapshot.path)
        try store.linkForMLXAudio(nemotron, snapshot: snapshot) // relinking replaces it
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == snapshot.path)

        try store.linkForMLXAudio(Self.gemma, snapshot: snapshot) // language models aren't linked
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("mlx-audio/mlx-community_gemma-4-E4B-it-qat-4bit").path))
    }

    /// Regression: the former placeholder reported "ready" for a 23-byte fake `model.bin`.
    @Test func legacyPlaceholderIsNotReportedAsReadyAndIsRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("gemma-4-e4b", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try write("model.bin", in: legacy, contents: "Gemma 4 E4B MLX Weights")

        let store = ModelStore(modelsDirectory: directory)
        #expect(store.state(of: Self.gemma).status == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func allocatedSizeCountsSymlinkedBlobsOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blob = directory.appendingPathComponent("blob")
        try Data(count: 64 * 1024).write(to: blob)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: blob)

        let size = ModelStore.allocatedSize(of: directory)
        #expect(size >= 64 * 1024)
        #expect(size < 2 * 64 * 1024)
    }

    @Test func loadingWithoutDownloadThrowsNotDownloaded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = LanguageModelRuntime(store: ModelStore(modelsDirectory: directory))
        await #expect(throws: LocalModelError.notDownloaded) {
            _ = try await runtime.load(Self.gemma)
        }
        await #expect(throws: LocalModelError.unknownModel("parakeet-tdt-v3")) {
            _ = try await runtime.load(ModelCatalog.model("parakeet-tdt-v3")!) // not a language model
        }
    }

    /// Opt-in: loads the real downloaded model. Run with `TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1 xcodebuild test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func downloadedModelLoadsAndAnswers() async throws {
        let runtime = LanguageModelRuntime.shared
        #expect(runtime.store.state(of: Self.gemma).status == .ready)
        #expect(runtime.store.state(of: Self.gemma).totalBytes > 5_000_000_000)

        let container = try await runtime.load(Self.gemma)
        #expect(runtime.loadedModel == Self.gemma)
        #expect(runtime.contextWindow == 131_072)
        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 20, temperature: 0))
        let answer = try await session.respond(to: "Reply with exactly one word: what is the capital of France?")
        #expect(answer.localizedCaseInsensitiveContains("paris"))

        runtime.unloadModel()
        #expect(!runtime.isLoaded)
        #expect(runtime.contextWindow == nil)
        #expect(runtime.store.state(of: Self.gemma).status == .ready) // unloading keeps the files
    }

    @Test func availableMemoryIsPositiveAndBounded() {
        let available = ModelStore.availableMemoryBytes()
        #expect(available > 0)
        #expect(available <= Int64(ProcessInfo.processInfo.physicalMemory))
    }
}
