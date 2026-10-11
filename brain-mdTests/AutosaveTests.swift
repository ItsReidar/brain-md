//
//  AutosaveTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

@MainActor
struct AutosaveTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-autosave-\(UUID().uuidString)")
    private var vaultURL: URL { root.appendingPathComponent("Vault") }
    private var outsideURL: URL { root.appendingPathComponent("Downloads/readme.md") }
    private let delay: TimeInterval = 0.05

    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# A".write(to: vaultURL.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# B".write(to: vaultURL.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "# Outside".write(to: outsideURL, atomically: true, encoding: .utf8)
        return VaultManager(customVaultURL: vaultURL)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: vaultURL.appendingPathComponent(name), encoding: .utf8)
    }

    /// Types `text` the way the editor binding does.
    private func type(_ text: String, in vault: VaultManager) {
        vault.editorContent = text
        vault.hasUnsavedChanges = true
        vault.scheduleAutosave(after: delay)
    }

    private func waitPastDelay() async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 6 * 1_000_000_000))
    }

    @Test func editsAreSavedAfterTheDelay() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "a.md")
        type("# A edited", in: vault)
        #expect(try read("a.md") == "# A") // not before the delay
        try await waitPastDelay()
        #expect(try read("a.md") == "# A edited")
        #expect(!vault.hasUnsavedChanges)
    }

    @Test func eachEditRestartsTheDelay() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "a.md")
        type("# A 1", in: vault)
        vault.scheduleAutosave(after: 10) // still typing: the next keystroke pushes the save out
        try await waitPastDelay()
        #expect(try read("a.md") == "# A")
        #expect(vault.hasUnsavedChanges)
    }

    @Test func filesOutsideTheVaultAreSavedToThemselves() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: outsideURL)
        type("# Outside edited", in: vault)
        try await waitPastDelay()
        #expect(try String(contentsOf: outsideURL, encoding: .utf8) == "# Outside edited")
        #expect(!FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("readme.md").path))
    }

    @Test func aPendingSaveDoesNotFireForTheNextNote() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "a.md")
        type("# A edited", in: vault)
        vault.selectNote(byRelativePath: "b.md") // the switch saves a.md itself
        vault.editorContent = "# B edited"
        vault.hasUnsavedChanges = true // e.g. an edit whose own autosave hasn't been scheduled yet
        try await waitPastDelay()
        #expect(try read("a.md") == "# A edited")
        #expect(try read("b.md") == "# B")
        #expect(vault.hasUnsavedChanges)
    }

    @Test func nothingIsSavedWhileSuspendedThenSavedWhenResumed() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "a.md")
        vault.isAutosaveSuspended = true // a meeting transcript is being written
        type("# A\n- **Speaker 1** [00:01] Hello", in: vault)
        try await waitPastDelay()
        #expect(try read("a.md") == "# A")

        vault.isAutosaveSuspended = false
        vault.scheduleAutosave(after: delay)
        try await waitPastDelay()
        #expect(try read("a.md") == "# A\n- **Speaker 1** [00:01] Hello")
    }

    @Test func theDelayComesFromSettings() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: VaultManager.autosaveDelayKey)
        defer { defaults.set(saved, forKey: VaultManager.autosaveDelayKey) }
        let vault = VaultManager(customVaultURL: root.appendingPathComponent("Vault"))
        defer { try? FileManager.default.removeItem(at: root) }

        defaults.set(3.0, forKey: VaultManager.autosaveDelayKey)
        #expect(vault.autosaveDelay == 3.0)
        defaults.removeObject(forKey: VaultManager.autosaveDelayKey)
        #expect(vault.autosaveDelay == 1.0)
    }
}
