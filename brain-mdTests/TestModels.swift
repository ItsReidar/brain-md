//
//  TestModels.swift
//  brain-mdTests
//

import Foundation
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
}
