//
//  ExternalFilesTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

@MainActor
struct ExternalFilesTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-external-\(UUID().uuidString)")
    private var vaultURL: URL { root.appendingPathComponent("Vault") }
    private var outsideURL: URL { root.appendingPathComponent("Downloads/readme.md") }

    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: vaultURL.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# In vault".write(to: vaultURL.appendingPathComponent("Projects/plan.md"), atomically: true, encoding: .utf8)
        try "# Outside\n\nHello".write(to: outsideURL, atomically: true, encoding: .utf8)
        return VaultManager(customVaultURL: vaultURL)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func aFileOutsideTheVaultOpensInTheEditor() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: outsideURL)
        let item = try #require(vault.selectedItem)
        #expect(item.isExternal)
        #expect(item.url == outsideURL.standardizedFileURL.resolvingSymlinksInPath())
        #expect(vault.editorContent == "# Outside\n\nHello")
        #expect(vault.editorTitle == "readme")
        #expect(!vault.hasUnsavedChanges)
    }

    @Test func aFileInsideTheVaultOpensAsTheVaultNote() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: vaultURL.appendingPathComponent("Projects/plan.md"))
        let item = try #require(vault.selectedItem)
        #expect(!item.isExternal)
        #expect(item.relativePath == "Projects/plan.md")
    }

    @Test func savingWritesBackToTheOutsideFileNotTheVault() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: outsideURL)
        vault.editorContent = "# Outside\n\nEdited"
        vault.hasUnsavedChanges = true
        vault.saveCurrentNote()
        #expect(try read(outsideURL) == "# Outside\n\nEdited")
        #expect(!vault.hasUnsavedChanges)
        #expect(!FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("readme.md").path))
    }

    @Test func switchingToAVaultNoteSavesTheOutsideFileFirst() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: outsideURL)
        vault.editorContent = "changed"
        vault.hasUnsavedChanges = true
        vault.selectNote(byRelativePath: "Projects/plan.md")
        #expect(try read(outsideURL) == "changed")
        #expect(vault.selectedItem?.isExternal == false)
    }

    @Test func addToVaultCopiesTheEditsAndLeavesTheOriginal() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Taken".write(to: vaultURL.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        vault.openFile(at: outsideURL)
        vault.editorContent = "# Outside\n\nWith my edits"
        vault.hasUnsavedChanges = true

        let path = try vault.addExternalFileToVault()
        #expect(path == "readme 1.md") // "readme.md" already exists in the vault
        #expect(try read(vaultURL.appendingPathComponent(path)) == "# Outside\n\nWith my edits")
        #expect(try read(outsideURL) == "# Outside\n\nHello")
        #expect(vault.selectedItem?.relativePath == path)
        #expect(vault.selectedItem?.isExternal == false)
        #expect(throws: BrainError.self) { try vault.addExternalFileToVault() }
    }

    @Test func onlyMarkdownFilesOpen() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("Downloads/photo.png")
        try Data([0x89]).write(to: image)
        let before = vault.selectedItem
        MarkdownFiles.open([image], vault: vault)
        #expect(vault.selectedItem == before)
        MarkdownFiles.open([image, outsideURL], vault: vault)
        #expect(vault.selectedItem?.name == "readme.md")
        #expect(MarkdownFiles.isMarkdown(URL(fileURLWithPath: "/tmp/a.MARKDOWN")))
        #expect(!MarkdownFiles.isMarkdown(URL(string: "https://example.com/a.md")!))
    }

    @Test func theBrainCommandShipsInTheApp() throws {
        let script = try #require(Bundle.main.url(forResource: "brain", withExtension: nil))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(try String(contentsOf: script, encoding: .utf8).contains("open -b \(Bundle.main.bundleIdentifier!)"))
    }

    @Test func relativePathsOnlyForFilesInsideTheVault() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(vault.relativePathInVault(vaultURL.appendingPathComponent("Projects/plan.md")) == "Projects/plan.md")
        #expect(vault.relativePathInVault(outsideURL) == nil)
        // A sibling folder whose name starts with the vault's isn't inside it.
        #expect(vault.relativePathInVault(root.appendingPathComponent("Vault2/x.md")) == nil)
    }
}
