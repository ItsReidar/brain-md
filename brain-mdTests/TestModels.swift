//
//  TestModels.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

/// Runtimes for tests, independent of the model the user picked in Settings.
@MainActor
enum TestModels {
    static let gemma = ModelCatalog.model(ModelCatalog.defaultLanguageModelID)!

    /// Real downloads, with Gemma 4 E4B selected (the model the opt-in real-model tests expect).
    static let gemmaRuntime: LanguageModelRuntime = {
        let defaults = UserDefaults(suiteName: "brainmd-tests-gemma-runtime")!
        defaults.set(gemma.id, forKey: ModelSelection.languageModelKey)
        return LanguageModelRuntime(store: .shared, defaults: defaults)
    }()

    /// An empty models folder: nothing is installed, so nothing can load.
    static func isolatedRuntime() -> LanguageModelRuntime {
        LanguageModelRuntime(store: ModelStore(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    /// Downloads `model` at its pinned revision unless it's already installed.
    static func install(_ model: ModelDescriptor, store: ModelStore = .shared) async throws {
        store.refresh(model)
        if store.isInstalled(model) { return }
        store.startDownload(model)
        while store.state(of: model).status == .downloading {
            try await Task.sleep(for: .milliseconds(500))
        }
        let state = store.state(of: model)
        #expect(state.status == .ready, "\(model.id): \(state.errorMessage ?? "")")
        if state.status != .ready { throw LocalModelError.notDownloaded }
    }
}
