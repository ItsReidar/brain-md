//
//  SemanticSearch.swift
//  brain-md
//

import Combine
import Foundation

/// Search by meaning for the sidebar. Each search first embeds notes that are new or changed
/// since the last one, so nothing runs in the background; the model unloads after a few idle minutes.
@MainActor
final class SemanticSearch: ObservableObject {
    static let shared = SemanticSearch()

    @Published private(set) var results: [NoteSearchResult] = []
    /// Notes embedded so far and how many need it, while indexing.
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    static let debounce: Duration = .milliseconds(400)

    private let vault: VaultManager
    private let store: ModelStore
    private let index: SemanticIndex
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(
        vault: VaultManager = .shared, store: ModelStore = .shared, index: SemanticIndex = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.vault = vault
        self.store = store
        self.index = index
        self.defaults = defaults
    }

    var model: ModelDescriptor { ModelSelection.embeddingModel(defaults) }

    /// On-device AI is on, the Mac runs MLX and the selected search model is downloaded.
    var isAvailable: Bool {
        ModelSelection.isOnDeviceAIEnabled(defaults) && ModelStore.isSupportedHardware && store.isInstalled(model)
    }

    /// Replaces any search in progress; an empty query clears the results.
    func search(_ query: String) {
        task?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            reset()
            return
        }
        guard isAvailable, let directory = store.snapshotDirectory(of: model) else {
            errorMessage = "Download a search model in Settings › Local AI & Voice › Semantic Search."
            return
        }
        let embedder = LocalEmbedder(model: model, directory: directory)
        let notes = noteSources()
        let vaultURL = vault.vaultURL
        task = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer {
                isSearching = false
                progress = nil
            }
            do {
                try await index.update(notes: notes, vaultURL: vaultURL, embedder: embedder) { done, total in
                    Task { @MainActor [weak self] in self?.progress = done < total ? (done, total) : nil }
                }
                let matches = try await index.search(query, vaultURL: vaultURL, embedder: embedder)
                try Task.checkCancellation()
                results = matches.map {
                    NoteSearchResult(relativePath: $0.relativePath, title: $0.title, snippet: $0.excerpt)
                }
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Stops a search or indexing run; what's indexed so far is kept.
    func cancel() {
        task?.cancel()
        task = nil
        isSearching = false
        progress = nil
    }

    func reset() {
        cancel()
        results = []
        errorMessage = nil
    }

    /// Markdown notes outside the app folders (Skills, attachments), as the index needs them.
    func noteSources() -> [IndexedNoteSource] {
        var sources: [IndexedNoteSource] = []
        func collect(_ items: [NoteItem]) {
            for item in items {
                if let children = item.children { collect(children) }
                guard !item.isDirectory, item.isMarkdown, !vault.isInAppFolder(item.relativePath) else { continue }
                sources.append(IndexedNoteSource(
                    relativePath: item.relativePath, url: item.url, title: item.displayName,
                    modifiedAt: item.modifiedAt, size: item.size))
            }
        }
        collect(vault.rootItems)
        return sources
    }
}
