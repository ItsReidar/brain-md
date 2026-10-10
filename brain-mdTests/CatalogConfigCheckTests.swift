//
//  CatalogConfigCheckTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_CATALOG_CHECK=1`, network): every catalog entry exists at its pinned revision,
/// has safetensors weights, and declares an architecture the pinned packages load. Reads only file
/// lists and `config.json`, never weights.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_CATALOG_CHECK"] == "1"))
struct CatalogConfigCheckTests {
    /// Language architectures the catalog relies on, all registered in mlx-swift-lm 3.32.3.
    static let languageTypes: Set = ["gemma4", "gemma4_unified", "qwen3_5", "mistral3", "mistral"]
    /// `model_type` values mlx-audio-swift 0.1.5 accepts per engine (Parakeet configs have none).
    static let speechTypes: [String: Set<String?>] = [
        "parakeet": [nil, "parakeet"],
        "nemotron_asr": ["nemotron_asr", "nemotron"],
        "whisper": ["whisper"],
        "voxtral_realtime": ["voxtral_realtime", "voxtral"],
    ]

    static func json(_ url: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(url)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test(arguments: ModelCatalog.all)
    func entryResolves(_ model: ModelDescriptor) async throws {
        let info = try await Self.json("https://huggingface.co/api/models/\(model.repo)/revision/\(model.revision)")
        let files = ((info["siblings"] as? [[String: Any]]) ?? []).compactMap { $0["rfilename"] as? String }
        #expect(files.contains { $0.hasSuffix(".safetensors") }, "\(model.id) has no safetensors")
        #expect(files.contains("config.json"), "\(model.id) has no config.json")

        let config = try await Self.json("https://huggingface.co/\(model.repo)/resolve/\(model.revision)/config.json")
        let type = config["model_type"] as? String
        switch model.kind {
        case .language:
            #expect(files.contains("tokenizer.json"), "\(model.id) has no tokenizer.json")
            #expect(type.map(Self.languageTypes.contains) == true, "\(model.id): \(type ?? "nil")")
        case .speech(let engine, _):
            #expect(Self.speechTypes[engine]?.contains(type) == true, "\(model.id): \(type ?? "nil")")
        case .diarizer(let maxSpeakers):
            #expect(type == "sortformer", "\(model.id): \(type ?? "nil")")
            #expect(config["num_speakers"] as? Int == maxSpeakers, "\(model.id)")
        }
    }
}
