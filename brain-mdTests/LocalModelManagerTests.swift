//
//  LocalModelManagerTests.swift
//  brain-mdTests
//

import Foundation
import MLXLMCommon
import Testing
@testable import brain_md

@MainActor
struct LocalModelManagerTests {

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
        #expect(LocalModelManager.isSupportedHardware)
        #else
        #expect(!LocalModelManager.isSupportedHardware)
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
        #expect(!LocalModelManager.snapshotIsComplete(directory))

        try write("model-00002-of-00002.safetensors", in: directory, contents: "x")
        #expect(LocalModelManager.snapshotIsComplete(directory))
    }

    @Test func snapshotWithoutConfigOrTokenizerIsIncomplete() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("model.safetensors", in: directory, contents: "x")
        #expect(!LocalModelManager.snapshotIsComplete(directory))

        try write("config.json", in: directory)
        try write("tokenizer.json", in: directory)
        #expect(LocalModelManager.snapshotIsComplete(directory))
    }

    /// Regression: the former placeholder reported "ready" for a 23-byte fake `model.bin`.
    @Test func legacyPlaceholderIsNotReportedAsReadyAndIsRemoved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("gemma-4-e4b", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try write("model.bin", in: legacy, contents: "Gemma 4 E4B MLX Weights")

        let manager = LocalModelManager(modelsDirectory: directory)
        #expect(manager.state.status == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func allocatedSizeCountsSymlinkedBlobsOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blob = directory.appendingPathComponent("blob")
        try Data(count: 64 * 1024).write(to: blob)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: blob)

        let size = LocalModelManager.allocatedSize(of: directory)
        #expect(size >= 64 * 1024)
        #expect(size < 2 * 64 * 1024)
    }

    @Test func loadingWithoutDownloadThrowsNotDownloaded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = LocalModelManager(modelsDirectory: directory)
        await #expect(throws: LocalModelError.notDownloaded) {
            _ = try await manager.loadModel()
        }
    }

    /// Opt-in: loads the real downloaded model. Run with `TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1 xcodebuild test …`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_MODEL_INTEGRATION"] == "1"))
    func downloadedModelLoadsAndAnswers() async throws {
        let manager = LocalModelManager()
        #expect(manager.state.status == .ready)
        #expect(manager.state.totalBytes > 5_000_000_000)

        let container = try await manager.loadModel()
        #expect(manager.isLoaded)
        let session = ChatSession(container, generateParameters: GenerateParameters(maxTokens: 20, temperature: 0))
        let answer = try await session.respond(to: "Reply with exactly one word: what is the capital of France?")
        #expect(answer.localizedCaseInsensitiveContains("paris"))

        manager.unloadModel()
        #expect(!manager.isLoaded)
        #expect(manager.state.status == .ready) // unloading keeps the files
    }

    @Test func availableMemoryIsPositiveAndBounded() {
        let available = LocalModelManager.availableMemoryBytes()
        #expect(available > 0)
        #expect(available <= Int64(ProcessInfo.processInfo.physicalMemory))
    }
}
