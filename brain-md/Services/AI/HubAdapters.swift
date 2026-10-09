//
//  HubAdapters.swift
//  brain-md
//
//  Bridges swift-huggingface (downloads) and swift-transformers (tokenizers) to the
//  protocols mlx-swift-lm expects. Equivalent to what the MLXHuggingFace macros
//  generate, written out to avoid Xcode's macro-trust prompt and the swift-syntax build.
//

import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers

nonisolated enum HubAdapterError: LocalizedError {
    case invalidRepositoryID(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id): "Invalid Hugging Face repository ID: \(id)"
        }
    }
}

/// Downloads model snapshots into a `HubCache`, reporting real byte progress.
nonisolated struct HubDownloader: MLXLMCommon.Downloader {
    let client: HubClient

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw HubAdapterError.invalidRepositoryID(id)
        }
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

nonisolated struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers names this `decode(tokens:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
