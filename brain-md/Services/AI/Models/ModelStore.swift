//
//  ModelStore.swift
//  brain-md
//

import Combine
import Darwin
import Foundation
import HuggingFace
import MLXLMCommon
import os

public enum LocalModelError: LocalizedError, Equatable {
    case notDownloaded
    case incompleteDownload
    case insufficientMemory(requiredBytes: Int64, availableBytes: Int64)
    case requiresAppleSilicon
    case unknownModel(String)

    public var errorDescription: String? {
        switch self {
        case .notDownloaded:
            "The model isn't downloaded. Download it in Settings › Local AI & Voice."
        case .incompleteDownload:
            "The model download is incomplete. Remove it in Settings and download it again."
        case .insufficientMemory(let required, let available):
            "Not enough free memory to load the model: it needs about \(Self.gigabytes(required)), "
                + "\(Self.gigabytes(available)) is available. Close other apps or pick a smaller model."
        case .requiresAppleSilicon:
            "On-device AI needs a Mac with Apple Silicon: MLX runs models on its GPU."
        case .unknownModel(let id):
            "Unknown model “\(id)”."
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// Downloads, verifies and deletes every catalog model, at its pinned revision, in one Hugging Face cache.
public final class ModelStore: ObservableObject {
    public static let shared = ModelStore()

    @Published public private(set) var states: [ModelDescriptor.ID: ModelDownloadState] = [:]

    public let modelsDirectory: URL
    let hubCache: HubCache
    private var downloads: [ModelDescriptor.ID: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "ModelStore")

    public static var defaultModelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brain-md/models", isDirectory: true)
    }

    /// Points `HubCache.default` at the app's models folder. mlx-audio-swift loads some models through
    /// the default cache only (Voxtral), so this must run before any of them load.
    public static func configureDefaultCache(_ directory: URL = defaultModelsDirectory) {
        setenv("HF_HUB_CACHE", directory.path, 1)
    }

    public init(modelsDirectory: URL = ModelStore.defaultModelsDirectory) {
        self.modelsDirectory = modelsDirectory
        self.hubCache = HubCache(cacheDirectory: modelsDirectory)
        // The 1.0 placeholder wrote a fake weights file here; it was never a real model.
        try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent("gemma-4-e4b"))
        refreshAll()
    }

    // MARK: - State

    public func state(of model: ModelDescriptor) -> ModelDownloadState {
        states[model.id] ?? ModelDownloadState(modelIdentifier: model.repo)
    }

    public func isInstalled(_ model: ModelDescriptor) -> Bool { state(of: model).status == .ready }

    public func refreshAll() {
        for model in ModelCatalog.all where downloads[model.id] == nil { refresh(model) }
    }

    public func refresh(_ model: ModelDescriptor) {
        if let directory = snapshotDirectory(of: model) {
            let size = Self.allocatedSize(of: repositoryDirectory(of: model))
            states[model.id] = ModelDownloadState(
                status: .ready, progress: 1, bytesDownloaded: size, totalBytes: size,
                modelIdentifier: model.repo, localPath: directory.path)
        } else {
            states[model.id] = ModelDownloadState(modelIdentifier: model.repo)
        }
    }

    /// The pinned snapshot, if every file needed to load it is present.
    public func snapshotDirectory(of model: ModelDescriptor) -> URL? {
        guard let repo = Repo.ID(rawValue: model.repo),
              let directory = try? hubCache.snapshotPath(repo: repo, kind: .model, commitHash: model.revision),
              Self.snapshotIsComplete(directory, for: model)
        else { return nil }
        return directory
    }

    func repositoryDirectory(of model: ModelDescriptor) -> URL {
        hubCache.repoDirectory(repo: Repo.ID(rawValue: model.repo)!, kind: .model)
    }

    /// Bytes the model occupies on disk, including partial downloads.
    public func diskUsageBytes(of model: ModelDescriptor) -> Int64 {
        Self.allocatedSize(of: repositoryDirectory(of: model))
    }

    // MARK: - Download

    public func startDownload(_ model: ModelDescriptor) {
        guard downloads[model.id] == nil, !isInstalled(model) else { return }
        states[model.id] = ModelDownloadState(
            status: .downloading, totalBytes: model.approximateBytes, modelIdentifier: model.repo)
        let downloader = HubDownloader(client: HubClient(cache: hubCache))
        log.info("Downloading \(model.repo, privacy: .public)@\(model.revision, privacy: .public)")

        let reportProgress: @Sendable (Progress) -> Void = { progress in
            // The aggregate Progress tracks fractions reliably but not completed bytes.
            let total = max(progress.totalUnitCount, 0)
            let done = Int64(progress.fractionCompleted * Double(total))
            Task { @MainActor in self.updateProgress(model, bytesDownloaded: done, totalBytes: total) }
        }

        downloads[model.id] = Task { [weak self] in
            do {
                let directory = try await downloader.download(
                    id: model.repo, revision: model.revision, matching: model.downloadPatterns,
                    useLatest: false, progressHandler: reportProgress)
                try Task.checkCancellation()
                guard let self else { return }
                self.downloads[model.id] = nil
                guard Self.snapshotIsComplete(directory, for: model) else { throw LocalModelError.incompleteDownload }
                try self.linkForMLXAudio(model, snapshot: directory)
                self.refresh(model)
            } catch {
                guard let self else { return }
                self.downloads[model.id] = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.log.info("Download of \(model.id, privacy: .public) cancelled")
                    self.refresh(model)
                } else {
                    self.log.error("Download of \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    var state = self.state(of: model)
                    state.status = .error
                    state.errorMessage = error.localizedDescription
                    self.states[model.id] = state
                }
            }
        }
    }

    private func updateProgress(_ model: ModelDescriptor, bytesDownloaded: Int64, totalBytes: Int64) {
        guard var state = states[model.id], state.status == .downloading else { return }
        state.bytesDownloaded = bytesDownloaded
        state.totalBytes = totalBytes
        state.progress = totalBytes > 0 ? min(1, Double(bytesDownloaded) / Double(totalBytes)) : 0
        states[model.id] = state
    }

    public func cancelDownload(_ model: ModelDescriptor) {
        downloads[model.id]?.cancel()
    }

    /// Cancels any download and deletes the model's files. Unloading is the runtimes' job.
    public func remove(_ model: ModelDescriptor) {
        downloads[model.id]?.cancel()
        downloads[model.id] = nil
        try? FileManager.default.removeItem(at: mlxAudioDirectory(of: model))
        try? FileManager.default.removeItem(at: repositoryDirectory(of: model))
        refresh(model)
    }

    // MARK: - mlx-audio-swift

    /// mlx-audio-swift loads speech models by repository name from `<cache>/mlx-audio/<org>_<name>` and
    /// downloads the latest revision when that folder is missing. Linking the verified pinned snapshot
    /// there makes it load offline, at the revision brain-md pinned.
    ///
    /// The folder is real, with one link per file. A folder that's itself a link can fail to list
    /// ("Not a directory"); mlx-audio then treats the model as incomplete and deletes its Hub cache
    /// entry, which is the snapshot brain-md downloaded.
    func mlxAudioDirectory(of model: ModelDescriptor) -> URL {
        modelsDirectory.appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(model.repo.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    func linkForMLXAudio(_ model: ModelDescriptor, snapshot: URL) throws {
        guard model.isSpeechModel || model.isDiarizer else { return }
        let folder = mlxAudioDirectory(of: model)
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil || fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder) // removes only the links, never the snapshot's files
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(atPath: snapshot.path) {
            try fm.createSymbolicLink(
                atPath: folder.appendingPathComponent(file).path,
                withDestinationPath: snapshot.appendingPathComponent(file).path)
        }
    }

    /// Re-creates missing or outdated links, e.g. for a snapshot linked by an earlier version.
    func ensureMLXAudioLink(_ model: ModelDescriptor) throws -> URL {
        guard let snapshot = snapshotDirectory(of: model) else { throw LocalModelError.notDownloaded }
        if !Self.links(mlxAudioDirectory(of: model), toEveryFileIn: snapshot) {
            try linkForMLXAudio(model, snapshot: snapshot)
        }
        return snapshot
    }

    nonisolated static func links(_ folder: URL, toEveryFileIn snapshot: URL) -> Bool {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil,
              let files = try? fm.contentsOfDirectory(atPath: snapshot.path), !files.isEmpty
        else { return false }
        return files.allSatisfy {
            (try? fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent($0).path))
                == snapshot.appendingPathComponent($0).path
        }
    }

    // MARK: - Hardware

    /// MLX needs an Apple Silicon GPU. The universal app's Intel slice builds, but must not load models.
    nonisolated public static var isSupportedHardware: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    // MARK: - Helpers

    /// True when the config and every weight file referenced by the index exist; language models
    /// also need their tokenizer.
    nonisolated static func snapshotIsComplete(_ directory: URL, for model: ModelDescriptor) -> Bool {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        guard exists("config.json") else { return false }
        if model.isLanguageModel, !exists("tokenizer.json") { return false }

        let index = directory.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: index),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            return !weightMap.isEmpty && Set(weightMap.values).allSatisfy(exists)
        }
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
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
