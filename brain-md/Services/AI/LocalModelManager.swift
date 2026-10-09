//
//  LocalModelManager.swift
//  brain-md
//

import Combine
import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXVLM
import os

public enum LocalModelError: LocalizedError, Equatable {
    case notDownloaded
    case incompleteDownload
    case insufficientMemory(requiredBytes: Int64, availableBytes: Int64)
    case requiresAppleSilicon

    public var errorDescription: String? {
        switch self {
        case .notDownloaded:
            "The Gemma 4 model isn't downloaded. Enable on-device AI in Settings."
        case .incompleteDownload:
            "The Gemma 4 download is incomplete. Remove it in Settings and download it again."
        case .insufficientMemory(let required, let available):
            "Not enough free memory to load Gemma 4: it needs about \(Self.gigabytes(required)), "
                + "\(Self.gigabytes(available)) is available. Close other apps and try again."
        case .requiresAppleSilicon:
            "On-device AI needs a Mac with Apple Silicon: MLX runs Gemma 4 on its GPU."
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// Downloads, verifies, loads and unloads the on-device Gemma 4 E4B model.
public final class LocalModelManager: ObservableObject {
    public static let shared = LocalModelManager()

    nonisolated static let repositoryID = "mlx-community/gemma-4-E4B-it-qat-4bit"
    /// Pinned commit: swift-transformers still ships yyjson 0.12.0 (GHSA-f4vc-345x-4mvm), so only
    /// this known set of JSON files is ever parsed.
    /// TODO: track `main` again once huggingface/swift-transformers#392 is released.
    nonisolated static let revision = "0f35c6f6d386f7f74e628bd7c6526ce531212300"
    nonisolated static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]
    /// Weights plus KV cache and activations: loading needs this much headroom over the file size.
    nonisolated static let memoryHeadroom = 1.2
    /// `@AppStorage` key for the "Enable on-device AI" setting.
    public static let enabledDefaultsKey = "ai_on_device_enabled"

    @Published public var state: ModelDownloadState
    @Published public private(set) var isLoaded = false

    public let modelsDirectory: URL
    private let hubCache: HubCache
    private var downloadTask: Task<Void, Never>?
    private var loadTask: Task<ModelContainer, Error>?
    private var container: ModelContainer?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "LocalModel")

    public static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brain-md/models", isDirectory: true)
    }

    public init(modelsDirectory: URL = LocalModelManager.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
        self.hubCache = HubCache(cacheDirectory: modelsDirectory)
        self.state = ModelDownloadState(modelIdentifier: Self.repositoryID)
        // The former placeholder wrote a fake weights file here; it was never a real model.
        try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent("gemma-4-e4b"))
        checkExistingModel()
    }

    private var repository: Repo.ID { Repo.ID(rawValue: Self.repositoryID)! }

    private var repositoryDirectory: URL { hubCache.repoDirectory(repo: repository, kind: .model) }

    /// The pinned snapshot directory, if every file needed to load the model is present.
    private func completeSnapshotDirectory() -> URL? {
        guard let directory = try? hubCache.snapshotPath(repo: repository, kind: .model, commitHash: Self.revision),
              Self.snapshotIsComplete(directory) else { return nil }
        return directory
    }

    // MARK: - State

    public func checkExistingModel() {
        guard downloadTask == nil else { return }
        if let directory = completeSnapshotDirectory() {
            let size = Self.allocatedSize(of: repositoryDirectory)
            state = ModelDownloadState(
                status: .ready, progress: 1.0, bytesDownloaded: size, totalBytes: size,
                modelIdentifier: Self.repositoryID, localPath: directory.path)
        } else {
            state = ModelDownloadState(modelIdentifier: Self.repositoryID)
        }
    }

    public func updateProgress(bytesDownloaded: Int64, totalBytes: Int64) {
        state.status = .downloading
        state.bytesDownloaded = bytesDownloaded
        state.totalBytes = totalBytes
        state.progress = totalBytes > 0 ? min(1.0, Double(bytesDownloaded) / Double(totalBytes)) : 0.0
    }

    public func completeDownload(localPath: String) {
        state.status = .ready
        state.progress = 1.0
        state.bytesDownloaded = state.totalBytes
        state.localPath = localPath
        state.errorMessage = nil
    }

    // MARK: - Download

    public func startDownload() {
        guard downloadTask == nil, state.status != .ready else { return }
        state = ModelDownloadState(status: .downloading, modelIdentifier: Self.repositoryID)
        let downloader = HubDownloader(client: HubClient(cache: hubCache))
        log.info("Downloading \(Self.repositoryID, privacy: .public)@\(Self.revision, privacy: .public)")

        let reportProgress: @Sendable (Progress) -> Void = { progress in
            // The aggregate Progress tracks fractions reliably but not completed bytes.
            let total = max(progress.totalUnitCount, 0)
            let done = Int64(progress.fractionCompleted * Double(total))
            Task { @MainActor in
                guard self.state.status == .downloading else { return }
                self.updateProgress(bytesDownloaded: done, totalBytes: total)
            }
        }

        downloadTask = Task { [weak self] in
            do {
                let directory = try await downloader.download(
                    id: Self.repositoryID, revision: Self.revision, matching: Self.downloadPatterns,
                    useLatest: false, progressHandler: reportProgress)
                try Task.checkCancellation()
                guard let self else { return }
                self.downloadTask = nil
                guard Self.snapshotIsComplete(directory) else { throw LocalModelError.incompleteDownload }
                self.checkExistingModel()
            } catch {
                guard let self else { return }
                self.downloadTask = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.log.info("Model download cancelled")
                    self.checkExistingModel()
                } else {
                    self.log.error("Model download failed: \(error.localizedDescription, privacy: .public)")
                    self.state.status = .error
                    self.state.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Bytes the model occupies on disk, including partial downloads.
    public func diskUsageBytes() -> Int64 {
        Self.allocatedSize(of: repositoryDirectory)
    }

    /// Cancels any download, unloads the model and deletes its files.
    public func removeModelCache() {
        downloadTask?.cancel()
        downloadTask = nil
        unloadModel()
        try? FileManager.default.removeItem(at: repositoryDirectory)
        state = ModelDownloadState(modelIdentifier: Self.repositoryID)
    }

    // MARK: - Load / Unload

    /// MLX needs an Apple Silicon GPU. The universal app's Intel slice builds, but must not load the model.
    public static var isSupportedHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Loads the model from disk (offline), or returns it if already loaded.
    public func loadModel() async throws -> ModelContainer {
        guard Self.isSupportedHardware else { throw LocalModelError.requiresAppleSilicon }
        if let container { return container }
        if let loadTask { return try await loadTask.value }
        guard let directory = completeSnapshotDirectory() else { throw LocalModelError.notDownloaded }

        let required = Int64(Double(Self.allocatedSize(of: repositoryDirectory)) * Self.memoryHeadroom)
        let available = Self.availableMemoryBytes()
        guard available >= required else {
            throw LocalModelError.insufficientMemory(requiredBytes: required, availableBytes: available)
        }

        let configuration = ModelConfiguration(
            directory: directory, defaultPrompt: "Describe the image in English", extraEOSTokens: ["<turn|>"])
        let downloader = HubDownloader(client: HubClient(cache: hubCache))
        let task = Task {
            var context = try await VLMModelFactory.shared.load(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
            context.processor = TextMaskDroppingProcessor(base: context.processor)
            return ModelContainer(context: context)
        }
        loadTask = task
        defer { loadTask = nil }
        let loaded = try await task.value
        container = loaded
        isLoaded = true
        log.info("Model loaded")
        return loaded
    }

    public func unloadModel() {
        loadTask?.cancel()
        container = nil
        guard isLoaded else { return }
        isLoaded = false
        MLX.Memory.clearCache()
        log.info("Model unloaded")
    }

    // MARK: - Helpers

    /// True when config, tokenizer and every weight file referenced by the index exist.
    nonisolated static func snapshotIsComplete(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard exists("config.json"), exists("tokenizer.json") else { return false }

        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            return !weightMap.isEmpty && Set(weightMap.values).allSatisfy(exists)
        }
        return exists("model.safetensors")
    }

    /// Bytes on disk, counting each blob once (snapshot entries are symlinks into `blobs/`).
    nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Memory macOS can hand out without paging: free, inactive, speculative, purgeable and file-backed pages.
    nonisolated static func availableMemoryBytes() -> Int64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Int64(ProcessInfo.processInfo.physicalMemory) }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
            + UInt64(stats.purgeable_count) + UInt64(stats.external_page_count)
        return Int64(pages * UInt64(vm_kernel_page_size))
    }
}
