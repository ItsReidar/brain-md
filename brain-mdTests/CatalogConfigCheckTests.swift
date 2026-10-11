//
//  CatalogConfigCheckTests.swift
//  brain-mdTests
//

import Foundation
import MLXLMCommon
import Testing
@testable import brain_md

/// Opt-in (`BRAINMD_CATALOG_CHECK=1`, network): every catalog entry exists at its pinned revision,
/// has safetensors weights, and declares an architecture the pinned packages load. Reads only file
/// lists and `config.json`, never weights.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BRAINMD_CATALOG_CHECK"] == "1"))
struct CatalogConfigCheckTests {
    /// Language architectures the catalog relies on, all registered in mlx-swift-lm 3.32.3.
    static let languageTypes: Set = ["gemma4", "gemma4_unified", "qwen3_5", "mistral3", "mistral"]
    /// Embedding architectures MLXEmbedders 3.32.3 registers (`gemma3_text` runs on the vendored copy).
    static let embeddingTypes: Set = ["gemma3_text", "qwen3", "xlm-roberta", "bert"]
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
            if model.fallbackChatTemplate == nil {
                let tokenizerConfig = try await Self.json(
                    "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/tokenizer_config.json")
                #expect(files.contains("chat_template.jinja") || tokenizerConfig["chat_template"] != nil,
                        "\(model.id) has no chat template; give it a fallbackChatTemplate")
            }
            #expect(type.map(Self.languageTypes.contains) == true, "\(model.id): \(type ?? "nil")")
        case .speech(let engine, _):
            #expect(Self.speechTypes[engine]?.contains(type) == true, "\(model.id): \(type ?? "nil")")
        case .diarizer(let maxSpeakers):
            #expect(type == "sortformer", "\(model.id): \(type ?? "nil")")
            #expect(config["num_speakers"] as? Int == maxSpeakers, "\(model.id)")
        case .embedding:
            #expect(files.contains("tokenizer.json"), "\(model.id) has no tokenizer.json")
            #expect(type.map(Self.embeddingTypes.contains) == true, "\(model.id): \(type ?? "nil")")
        }
    }

    /// Base checkpoints have no chat template: the bundled one renders Gemma turns with their tokenizer.
    @Test(arguments: ModelCatalog.languageModels.filter { $0.fallbackChatTemplate != nil })
    func fallbackChatTemplateRendersWithTheModelsTokenizer(_ model: ModelDescriptor) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["tokenizer.json", "tokenizer_config.json"] {
            let url = URL(string: "https://huggingface.co/\(model.repo)/resolve/\(model.revision)/\(file)")!
            try await URLSession.shared.data(from: url).0.write(to: folder.appendingPathComponent(file))
        }
        let template = try #require(ChatTemplates.template(named: model.fallbackChatTemplate!))
        let tokenizer = try await TransformersTokenizerLoader(fallbackChatTemplate: template).load(from: folder)
        let tokens = try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hallo!"]],
            tools: nil, additionalContext: nil)
        let text = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        #expect(text.hasPrefix("<bos><|turn>system\nBe brief.<turn|>"), "\(text)")
        #expect(text.contains("<|turn>user\nHallo!<turn|>"), "\(text)")
        #expect(text.hasSuffix("<|turn>model\n"), "\(text)")
        #expect(tokens.filter { $0 == 2 }.count == 1, "exactly one <bos>")
        // Without the fallback the model couldn't chat at all.
        #expect(throws: (any Error).self) {
            try TransformersTokenizer(upstream: (tokenizer as! TransformersTokenizer).upstream)
                .applyChatTemplate(messages: [["role": "user", "content": "Hi"]], tools: nil, additionalContext: nil)
        }
    }
}
