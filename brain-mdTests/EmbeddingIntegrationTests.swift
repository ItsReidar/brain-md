//
//  EmbeddingIntegrationTests.swift
//  brain-mdTests
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_EMBEDDING_INTEGRATION=1`): real embeddings from EmbeddingGemma 300M, the
/// default search model. Installs it (212 MB) into the app's models folder if missing.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAINMD_EMBEDDING_INTEGRATION"] == "1"))
struct EmbeddingIntegrationTests {
    static let gemma = ModelCatalog.model("embeddinggemma-300m")!

    static func embedder() async throws -> LocalEmbedder {
        try await TestModels.install(gemma)
        return LocalEmbedder(model: gemma, directory: try #require(ModelStore.shared.snapshotDirectory(of: gemma)))
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    @Test func vectorsAreNormalised() async throws {
        let vectors = try await Self.embedder().embed(["Hello world", "A longer sentence about the weather."], as: .document)
        #expect(vectors.count == 2)
        #expect(vectors[0].count == 768)
        for vector in vectors { #expect(abs(Self.dot(vector, vector) - 1) < 0.01) }
    }

    @Test func relatedTextScoresHigherInEnglishDutchAndAcross() async throws {
        let embedder = try await Self.embedder()
        let cases: [(query: String, related: String, unrelated: String)] = [
            ("budget overrun", "The project costs exceeded the plan by twenty percent.",
             "We adopted a new puppy last weekend."),
            ("wanneer is de deadline", "De oplevering moet uiterlijk vrijdag 14 november klaar zijn.",
             "Het recept vraagt om twee eieren en bloem."),
            ("vergadering over de lancering", "Meeting notes: the product launch moves two weeks.",
             "My favourite hiking trail is in the Ardennes."),
        ]
        var report: [String] = []
        for test in cases {
            let query = try await embedder.embed([test.query], as: .query)[0]
            let documents = try await embedder.embed([test.related, test.unrelated], as: .document)
            let related = Self.dot(query, documents[0]), unrelated = Self.dot(query, documents[1])
            report.append(String(format: "%@: related %.3f, unrelated %.3f", test.query, related, unrelated))
            #expect(related > unrelated + 0.05, "\(test.query): \(related) vs \(unrelated)")
        }
        try MLXSpeechIntegrationTests.report(report.joined(separator: "\n"))
    }

    /// A small vault: the right note is found by meaning, without sharing a word with the query.
    @Test func findsNotesByMeaningEndToEnd() async throws {
        let embedder = try await Self.embedder()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-semantic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let texts = [
            "Q3 review": "The project costs exceeded the plan by twenty percent, so finance wants a new forecast.",
            "Holiday": "We booked a cabin in the Ardennes for the autumn break.",
            "Recipes": "Grandma's apple pie: flour, butter, apples and cinnamon.",
            "Garden": "Planted tulip bulbs along the fence.",
            "Reading list": "Novels to read this winter, starting with a detective story.",
            "Car": "Winter tyres need to go on before November.",
            "Standup": "Backend migration finished; frontend still testing the login page.",
            "Hiring": "Interviewing two candidates for the data engineer role next week.",
            "Workout": "Ran five kilometres, legs sore afterwards.",
            "Movies": "Watched a documentary about deep-sea creatures.",
            "Kids": "School trip to the zoo on Thursday, pack lunch.",
            "Taxes": "Gather receipts for the yearly tax return.",
            "Music": "Practising a new piano piece by Satie.",
            "Plants": "The monstera needs repotting into a bigger pot.",
            "Ideas": "An app that reminds you to drink water.",
            "Dentist": "Check-up booked for the twelfth at nine.",
            "Moving": "Compare offers from three moving companies.",
            "Birthday": "Order a cake and invite the neighbours.",
            "Laptop": "Battery drains fast since the last update.",
            "Vergadering": "De klant wil de oplevering twee weken uitstellen.",
        ]
        var sources: [IndexedNoteSource] = []
        for (title, text) in texts {
            let url = vault.appendingPathComponent(title + ".md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            sources.append(IndexedNoteSource(relativePath: title + ".md", url: url, title: title,
                                             modifiedAt: Date(), size: Int64(text.utf8.count)))
        }
        let index = SemanticIndex(directory: root.appendingPathComponent("index"))
        try await index.update(notes: sources, vaultURL: vault, embedder: embedder)

        let budget = try await index.search("budget overrun", vaultURL: vault, embedder: embedder)
        #expect(budget.first?.relativePath == "Q3 review.md", "\(budget.prefix(3).map(\.relativePath))")
        let delay = try await index.search("project delayed", vaultURL: vault, embedder: embedder)
        #expect(delay.prefix(2).contains { $0.relativePath == "Vergadering.md" }, "\(delay.prefix(3).map(\.relativePath))")
        try MLXSpeechIntegrationTests.report(
            "budget overrun → \(budget.prefix(3).map { "\($0.relativePath) \(String(format: "%.3f", $0.score))" })\n"
            + "project delayed → \(delay.prefix(3).map { "\($0.relativePath) \(String(format: "%.3f", $0.score))" })")
    }

    /// The vendored bidirectional EmbeddingGemma separates related from unrelated text better than
    /// mlx-swift-lm 3.32.3's causal one, on the same weights.
    @Test func vendoredAttentionFixImprovesSeparation() async throws {
        let directory = try await Self.embedder().directory
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let packaged = try await EmbedderTypeRegistry.shared.createModel(configuration: configData, modelType: base.modelType)
        try await loadWeights(modelDirectory: directory, model: packaged, perLayerQuantization: base.perLayerQuantization)
        let tokenizer = try await TransformersTokenizerLoader().load(from: directory)
        func packagedVector(_ text: String) -> [Float] {
            let ids = tokenizer.encode(text: text, addSpecialTokens: true).map(Int32.init)
            let input = MLXArray(ids).reshaped(1, ids.count)
            let pooled = packaged(input, positionIds: nil, tokenTypeIds: nil, attentionMask: MLXArray.ones(like: input)).pooledOutput!
            return pooled[0].asType(.float32).asArray(Float.self)
        }
        guard case .embedding(_, let queryPrefix, let documentPrefix, _) = Self.gemma.kind else { return }
        let pairs = [
            ("budget overrun", "The project costs exceeded the plan by twenty percent.", "We adopted a new puppy last weekend."),
            ("wanneer is de deadline", "De oplevering moet uiterlijk vrijdag 14 november klaar zijn.", "Het recept vraagt om twee eieren en bloem."),
            ("vergadering over de lancering", "Meeting notes: the product launch moves two weeks.", "My favourite hiking trail is in the Ardennes."),
        ]
        let embedder = try await Self.embedder()
        var fixedMargin: Float = 0, causalMargin: Float = 0
        for (query, related, unrelated) in pairs {
            let fixed = try await embedder.embed([query], as: .query)[0]
            let fixedDocs = try await embedder.embed([related, unrelated], as: .document)
            fixedMargin += Self.dot(fixed, fixedDocs[0]) - Self.dot(fixed, fixedDocs[1])
            let causal = packagedVector(queryPrefix + query)
            causalMargin += Self.dot(causal, packagedVector(documentPrefix + related))
                - Self.dot(causal, packagedVector(documentPrefix + unrelated))
        }
        try MLXSpeechIntegrationTests.report(String(format: "mean margin: vendored %.3f, package (causal) %.3f",
                                                    fixedMargin / 3, causalMargin / 3))
        #expect(fixedMargin > causalMargin)
    }
}
