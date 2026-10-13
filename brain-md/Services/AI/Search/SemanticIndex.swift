//
//  SemanticIndex.swift
//  brain-md
//

import CryptoKit
import Foundation

/// A note as the index sees it: where it is and whether it changed.
nonisolated struct IndexedNoteSource: Sendable, Equatable {
    let relativePath: String
    let url: URL
    let title: String
    let modifiedAt: Date
    let size: Int64
}

/// One result: a note and its passage closest to the query.
nonisolated struct SemanticMatch: Sendable, Equatable, Codable {
    let relativePath: String
    let title: String
    let excerpt: String
    let score: Float
}

/// Splits a note into passages small enough to embed well: at headings and blank lines, merged up
/// to about `targetLength` characters, each prefixed with the note's title for context.
nonisolated enum NoteChunker {
    static let targetLength = 1_000

    static func chunks(title: String, markdown: String) -> [String] {
        let body = FrontmatterParser.parse(markdown).body
        var blocks: [String] = []
        var current: [String] = []
        func closeBlock() {
            let block = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { blocks.append(block) }
            current = []
        }
        for line in body.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                closeBlock()
            } else if line.hasPrefix("#") {
                closeBlock()
                blocks.append("\u{0}" + line) // marks a heading: it starts a new passage
            } else {
                current.append(line)
            }
        }
        closeBlock()

        var passages: [String] = []
        var passage = ""
        func closePassage() {
            let text = passage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { passages.append(text) }
            passage = ""
        }
        for block in blocks {
            if block.hasPrefix("\u{0}") {
                closePassage()
                passage = String(block.dropFirst())
                continue
            }
            if !passage.isEmpty, passage.count + block.count > targetLength { closePassage() }
            passage += (passage.isEmpty ? "" : "\n\n") + block
            // A single very long paragraph is cut so no passage greatly exceeds the target.
            while passage.count > 2 * targetLength {
                let cut = passage.index(passage.startIndex, offsetBy: targetLength)
                passages.append(String(passage[..<cut]))
                passage = String(passage[cut...])
            }
        }
        closePassage()
        let header = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return passages.map { header.isEmpty ? $0 : header + "\n" + $0 }
    }
}

/// Embeddings of every passage in the vault, kept on disk so only new or changed notes are
/// embedded again. One index per vault and model.
actor SemanticIndex {
    static let shared = SemanticIndex()
    static let defaultDirectory = ModelStore.defaultModelsDirectory.deletingLastPathComponent()
        .appendingPathComponent("index", isDirectory: true)
    /// Notes are saved in batches of this many, so a cancelled indexing run keeps its progress.
    static let saveInterval = 25

    struct Passage: Codable, Equatable {
        var excerpt: String
        /// Float32 values, L2-normalised.
        var vector: Data
    }

    struct Note: Codable, Equatable {
        var title: String
        var modifiedAt: Date
        var size: Int64
        var passages: [Passage]
    }

    struct Contents: Codable, Equatable {
        var modelID: String
        var notes: [String: Note] = [:]
    }

    let directory: URL
    private var contents: Contents?
    private var contentsURL: URL?

    init(directory: URL = SemanticIndex.defaultDirectory) {
        self.directory = directory
    }

    /// `<sha256 of the vault path>-<model id>.plist`.
    func fileURL(vaultURL: URL, modelID: String) -> URL {
        let digest = SHA256.hash(data: Data(vaultURL.standardizedFileURL.path.utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key)-\(modelID).plist")
    }

    /// Embeds new and changed notes, forgets removed ones and saves. `progress` gets (done, total)
    /// for the notes that needed embedding.
    func update(
        notes: [IndexedNoteSource], vaultURL: URL, embedder: any TextEmbedder,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        var contents = load(vaultURL: vaultURL, modelID: embedder.modelID)
        let current = Dictionary(notes.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        contents.notes = contents.notes.filter { current[$0.key] != nil }
        let changed = notes.filter { note in
            guard let indexed = contents.notes[note.relativePath] else { return true }
            return indexed.modifiedAt != note.modifiedAt || indexed.size != note.size
        }
        defer { self.contents = contents; save(contents) }
        progress(0, changed.count)
        for (offset, note) in changed.enumerated() {
            try Task.checkCancellation()
            let markdown = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            let chunks = NoteChunker.chunks(title: note.title, markdown: markdown)
            let vectors = chunks.isEmpty ? [] : try await embedder.embed(chunks, as: .document)
            contents.notes[note.relativePath] = Note(
                title: note.title, modifiedAt: note.modifiedAt, size: note.size,
                passages: zip(chunks, vectors).map {
                    Passage(excerpt: Self.excerpt($0, title: note.title), vector: Self.data($1))
                })
            progress(offset + 1, changed.count)
            if (offset + 1) % Self.saveInterval == 0 { self.contents = contents; save(contents) }
        }
    }

    /// The `limit` notes whose best passage is closest to `query`, best first.
    func search(_ query: String, vaultURL: URL, embedder: any TextEmbedder, limit: Int = 20) async throws
        -> [SemanticMatch]
    {
        let contents = load(vaultURL: vaultURL, modelID: embedder.modelID)
        guard let queryVector = try await embedder.embed([query], as: .query).first else { return [] }
        // shortcut: linear scan over every passage, fine to ~50k passages; use vDSP or an ANN index beyond that.
        var matches: [SemanticMatch] = []
        for (path, note) in contents.notes {
            var best: (score: Float, excerpt: String)?
            for passage in note.passages {
                let score = Self.dot(queryVector, passage.vector)
                if score > best?.score ?? -.infinity { best = (score, passage.excerpt) }
            }
            if let best, best.score > 0 {
                matches.append(SemanticMatch(relativePath: path, title: note.title, excerpt: best.excerpt, score: best.score))
            }
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Number of notes in this vault's index for the model, and the index file's size.
    func stats(vaultURL: URL, modelID: String) -> (notes: Int, bytes: Int64) {
        let url = fileURL(vaultURL: vaultURL, modelID: modelID)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return (load(vaultURL: vaultURL, modelID: modelID).notes.count, bytes)
    }

    /// Deletes index files: every model's when `modelID` is nil.
    func delete(modelID: String? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where modelID == nil || file.deletingPathExtension().lastPathComponent.hasSuffix("-" + modelID!) {
            try? FileManager.default.removeItem(at: file)
        }
        contents = nil
        contentsURL = nil
    }

    // MARK: - Storage

    private func load(vaultURL: URL, modelID: String) -> Contents {
        let url = fileURL(vaultURL: vaultURL, modelID: modelID)
        if let contents, contentsURL == url { return contents }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(Contents.self, from: $0) }
        let result = loaded?.modelID == modelID ? loaded! : Contents(modelID: modelID)
        contents = result
        contentsURL = url
        return result
    }

    private func save(_ contents: Contents) {
        guard let url = contentsURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(contents).write(to: url, options: .atomic)
        } catch {
            // The index is a cache: a failed save only means more embedding next time.
        }
    }

    // MARK: - Vectors

    static func data(_ vector: [Float]) -> Data { vector.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func dot(_ query: [Float], _ data: Data) -> Float {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            var sum: Float = 0
            for index in 0..<min(values.count, query.count) { sum += query[index] * values[index] }
            return sum
        }
    }

    /// The passage without its title line, shortened for a result snippet.
    static func excerpt(_ passage: String, title: String) -> String {
        let header = title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let body = passage.hasPrefix(header) && header.count > 1 ? String(passage.dropFirst(header.count)) : passage
        let text = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return text.count > 160 ? String(text.prefix(160)) + "…" : text
    }
}
