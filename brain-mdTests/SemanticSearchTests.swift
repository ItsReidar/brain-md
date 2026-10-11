//
//  SemanticSearchTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

/// Embeds by counting a few topic words, so tests can predict similarities without a model.
private actor FakeEmbedder: TextEmbedder {
    nonisolated let modelID: String
    private(set) var embedded: [String] = []

    init(modelID: String = "fake") { self.modelID = modelID }

    static let topics = ["budget", "launch", "recipe"]

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [[Float]] {
        if role == .document { embedded += texts }
        return texts.map { text in
            let lower = text.lowercased()
            var vector = Self.topics.map { Float(lower.components(separatedBy: $0).count - 1) } + [0.1]
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            vector = vector.map { $0 / norm }
            return vector
        }
    }

    func clear() { embedded = [] }
}

struct NoteChunkerTests {
    @Test func headingsStartPassagesAndTheTitleLeads() {
        let chunks = NoteChunker.chunks(title: "Plan", markdown: """
            ---
            tags: [work]
            ---
            Intro paragraph.

            # Budget
            Costs went up.

            ## Launch
            Moves two weeks.
            """)
        #expect(chunks == ["Plan\nIntro paragraph.", "Plan\n# Budget\n\nCosts went up.", "Plan\n## Launch\n\nMoves two weeks."])
        #expect(!chunks.joined().contains("tags:"))
    }

    @Test func shortParagraphsMergeAndLongOnesSplit() {
        let short = (1...5).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        #expect(NoteChunker.chunks(title: "T", markdown: short).count == 1)

        let long = String(repeating: "word ", count: 1_000) // 5,000 characters, no breaks
        let chunks = NoteChunker.chunks(title: "T", markdown: long)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.count <= 2 * NoteChunker.targetLength + 2 })
    }

    @Test func emptyNotesHaveNoPassages() {
        #expect(NoteChunker.chunks(title: "Empty", markdown: "").isEmpty)
        #expect(NoteChunker.chunks(title: "Empty", markdown: "---\ntitle: x\n---\n\n   \n").isEmpty)
    }
}

struct SemanticIndexTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-index-\(UUID().uuidString)")
    private var vault: URL { root.appendingPathComponent("Vault") }
    private var indexDirectory: URL { root.appendingPathComponent("index") }

    private func note(_ name: String, _ text: String, modified: Date = Date(timeIntervalSince1970: 1_000)) throws
        -> IndexedNoteSource
    {
        let url = vault.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return IndexedNoteSource(
            relativePath: name, url: url, title: (name as NSString).deletingPathExtension,
            modifiedAt: modified, size: Int64(text.utf8.count))
    }

    @Test func ranksNotesByTheirBestPassage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = [
            try note("Budget.md", "Intro: a recipe we liked.\n\n# Costs\nThe budget overran; budget review on Friday."),
            try note("Launch.md", "The launch slips two weeks."),
            try note("Dinner.md", "A recipe for pasta."),
        ]
        let index = SemanticIndex(directory: indexDirectory)
        let embedder = FakeEmbedder()
        try await index.update(notes: notes, vaultURL: vault, embedder: embedder)

        let results = try await index.search("budget", vaultURL: vault, embedder: embedder)
        #expect(results.first?.relativePath == "Budget.md")
        #expect(results.first?.excerpt.contains("budget overran") == true) // the matching passage, not the intro
        #expect(results.first?.title == "Budget")
        #expect(results.map(\.score) == results.map(\.score).sorted(by: >))
    }

    @Test func onlyChangedNotesAreEmbeddedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let index = SemanticIndex(directory: indexDirectory)
        let embedder = FakeEmbedder()
        var notes = [try note("A.md", "budget"), try note("B.md", "launch"), try note("C.md", "recipe")]
        try await index.update(notes: notes, vaultURL: vault, embedder: embedder)
        #expect(await embedder.embedded.count == 3)

        await embedder.clear()
        notes[1] = try note("B.md", "launch moved", modified: Date(timeIntervalSince1970: 2_000))
        notes.removeLast() // C.md deleted
        var reported: [(Int, Int)] = []
        let lock = NSLock()
        try await index.update(notes: notes, vaultURL: vault, embedder: embedder) { done, total in
            lock.withLock { reported.append((done, total)) }
        }
        #expect(await embedder.embedded == ["B\nlaunch moved"])
        #expect(lock.withLock { reported.map(\.0) == [0, 1] && reported.allSatisfy { $0.1 == 1 } })
        let stats = await index.stats(vaultURL: vault, modelID: "fake")
        #expect(stats.notes == 2)
    }

    @Test func theIndexSurvivesARestartAndIsPerVaultAndModel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = [try note("A.md", "budget")]
        try await SemanticIndex(directory: indexDirectory).update(notes: notes, vaultURL: vault, embedder: FakeEmbedder())

        // A fresh index (as after relaunching) loads from disk: nothing to embed.
        let reloaded = SemanticIndex(directory: indexDirectory)
        let embedder = FakeEmbedder()
        try await reloaded.update(notes: notes, vaultURL: vault, embedder: embedder)
        #expect(await embedder.embedded.isEmpty)

        // Another model or vault starts from scratch.
        let other = FakeEmbedder(modelID: "other")
        try await reloaded.update(notes: notes, vaultURL: vault, embedder: other)
        #expect(await other.embedded.count == 1)
        let elsewhere = await reloaded.fileURL(vaultURL: root.appendingPathComponent("Other"), modelID: "fake")
        #expect(elsewhere != (await reloaded.fileURL(vaultURL: vault, modelID: "fake")))

        await reloaded.delete(modelID: "fake")
        #expect(await reloaded.stats(vaultURL: vault, modelID: "fake").notes == 0)
        #expect(await reloaded.stats(vaultURL: vault, modelID: "other").notes == 1)
    }

    @Test func excerptsDropTheTitleAndStayShort() {
        #expect(SemanticIndex.excerpt("Plan\nCosts went up.", title: "Plan") == "Costs went up.")
        #expect(SemanticIndex.excerpt("No title here\nsecond line", title: "") == "No title here second line")
        #expect(SemanticIndex.excerpt("T\n" + String(repeating: "a", count: 300), title: "T").count == 161)
    }
}

struct EmbeddingModelTests {
    @Test func longInputsKeepTheirClosingToken() {
        let tokens = Array(0..<600)
        let cut = EmbeddingRuntime.truncated(tokens)
        #expect(cut.count == EmbeddingRuntime.maxTokens)
        #expect(cut.last == 599)
        #expect(EmbeddingRuntime.truncated([1, 2, 3]) == [1, 2, 3])
    }

    @Test func catalogEntriesAreCompleteAndFromMLXCommunity() throws {
        let models = ModelCatalog.embeddingModels
        #expect(models.map(\.id) == ["embeddinggemma-300m", "qwen3-embedding-0.6b", "arctic-embed-l-v2", "bge-small-en", "minilm-l6"])
        for model in models {
            #expect(model.repo.hasPrefix("mlx-community/"), "\(model.id)")
            #expect(model.revision.count == 40, "\(model.id)")
            #expect(model.capabilities.first == .search)
        }
        #expect(try #require(ModelCatalog.model(ModelCatalog.defaultEmbeddingModelID)).isEmbeddingModel)
        guard case .embedding(.model, let query, let document, true) = try #require(ModelCatalog.model("embeddinggemma-300m")).kind
        else { Issue.record("EmbeddingGemma pools itself and is multilingual"); return }
        #expect(query.hasPrefix("task: search result"))
        #expect(document.hasPrefix("title: none"))
    }

    @MainActor
    @Test func searchByMeaningNeedsAIOnAndTheModelDownloaded() throws {
        let name = "brainmd-tests-semantic-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let search = SemanticSearch(store: store, index: SemanticIndex(directory: store.modelsDirectory), defaults: defaults)

        defaults.set(true, forKey: ModelSelection.enabledKey)
        #expect(search.model.id == ModelCatalog.defaultEmbeddingModelID)
        #expect(!search.isAvailable) // not downloaded
        defaults.set("bge-small-en", forKey: ModelSelection.embeddingModelKey)
        #expect(search.model.id == "bge-small-en")
        defaults.set("gemma-4-e4b-qat", forKey: ModelSelection.embeddingModelKey) // not an embedding model
        #expect(search.model.id == ModelCatalog.defaultEmbeddingModelID)

        search.search("anything")
        #expect(search.errorMessage?.contains("Semantic Search") == true)
        #expect(search.results.isEmpty)
    }
}
