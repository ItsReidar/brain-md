//
//  SidebarOrderTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

struct SidebarOrderTests {
    private func note(_ name: String, in folder: String = "", modified: Double = 0, created: Double = 0) -> NoteItem {
        let path = folder.isEmpty ? "\(name).md" : "\(folder)/\(name).md"
        return NoteItem(
            name: name, relativePath: path, url: URL(fileURLWithPath: "/vault/\(path)"), isDirectory: false,
            modifiedAt: Date(timeIntervalSince1970: modified), createdAt: Date(timeIntervalSince1970: created))
    }

    private func folder(_ name: String, _ children: [NoteItem] = []) -> NoteItem {
        NoteItem(name: name, relativePath: name, url: URL(fileURLWithPath: "/vault/\(name)"), isDirectory: true, children: children)
    }

    private func names(_ items: [NoteItem]) -> [String] { items.map(\.name) }

    @Test func eachModeAndFoldersOrNotesFirst() {
        let items = [note("b", modified: 3, created: 1), folder("Zed"), note("a", modified: 1, created: 3), note("c", modified: 2, created: 2)]
        #expect(names(SidebarOrder.sorted(items, mode: .name, foldersFirst: true, custom: [:])) == ["Zed", "a", "b", "c"])
        #expect(names(SidebarOrder.sorted(items, mode: .name, foldersFirst: false, custom: [:])) == ["a", "b", "c", "Zed"])
        #expect(names(SidebarOrder.sorted(items, mode: .modified, foldersFirst: true, custom: [:])) == ["Zed", "b", "c", "a"])
        #expect(names(SidebarOrder.sorted(items, mode: .created, foldersFirst: true, custom: [:])) == ["Zed", "a", "c", "b"])
    }

    @Test func customOrderPutsNewItemsAfterTheListedOnesAndAppliesInFolders() {
        let items = [note("a"), note("b"), note("new"), folder("F", [note("x", in: "F"), note("y", in: "F")])]
        let custom = ["": ["b.md", "a.md"], "F": ["y.md", "x.md"]]
        let sorted = SidebarOrder.sorted(items, mode: .custom, foldersFirst: false, custom: custom)
        #expect(names(sorted) == ["b", "a", "new", "F"])
        #expect(names(sorted.last?.children ?? []) == ["y", "x"])
    }
}

@MainActor
struct SidebarOrderStoreTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-order-\(UUID().uuidString)")

    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for path in ["A.md", "B.md", "C.md", "Folder/X.md"] {
            try "# \(path)".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        return VaultManager(customVaultURL: root)
    }

    private func shown(_ vault: VaultManager, folder: String = "") -> [String] {
        let items = folder.isEmpty ? vault.rootItems : vault.noteItem(atRelativePath: folder)?.children ?? []
        return SidebarOrder.sorted(items, mode: .custom, foldersFirst: true, custom: vault.customOrder, folder: folder)
            .map(\.url.lastPathComponent)
    }

    @Test func draggingAboveANoteStartsFromWhatWasShownAndIsSavedInTheVault() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try #require(vault.noteItem(atRelativePath: "A.md"))
        try vault.moveInOrder("C.md", before: a, mode: .name, foldersFirst: true)
        #expect(shown(vault) == ["Folder", "C.md", "A.md", "B.md"])

        // A relaunch reads it back from the vault.
        let reopened = VaultManager(customVaultURL: root)
        #expect(shown(reopened) == ["Folder", "C.md", "A.md", "B.md"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".brain-md/sidebar-order.json").path))
        #expect(!reopened.rootItems.contains { $0.name == ".brain-md" }) // hidden from the sidebar
    }

    @Test func draggingIntoAnotherFolderMovesTheFileThere() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let x = try #require(vault.noteItem(atRelativePath: "Folder/X.md"))
        try vault.moveInOrder("B.md", before: x, mode: .custom, foldersFirst: true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder/B.md").path))
        #expect(shown(vault, folder: "Folder") == ["B.md", "X.md"])
    }

    @Test func renamingAndMovingKeepTheOrderInStep() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        try vault.moveInOrder("C.md", before: try #require(vault.noteItem(atRelativePath: "A.md")), mode: .name, foldersFirst: true)
        try vault.renameItem(oldRelativePath: "C.md", newName: "Renamed")
        #expect(shown(vault) == ["Folder", "Renamed.md", "A.md", "B.md"])

        try vault.moveItem(sourceRelativePath: "Renamed.md", toDirectoryRelativePath: "Folder")
        #expect(vault.customOrder[""] == ["Folder", "A.md", "B.md"]) // gone from the root's list

        try vault.moveInOrder("A.md", before: try #require(vault.noteItem(atRelativePath: "Folder/X.md")), mode: .custom, foldersFirst: true)
        try vault.renameItem(oldRelativePath: "Folder", newName: "Projects") // its order moves along
        #expect(vault.customOrder["Projects"] == ["Renamed.md", "A.md", "X.md"])
        #expect(vault.customOrder["Folder"] == nil)
    }

    @Test func aDamagedOrderFileMeansNoCustomOrder() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".brain-md"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: root.appendingPathComponent(".brain-md/sidebar-order.json"))
        let vault = try setUp()
        #expect(vault.customOrder.isEmpty)
    }
}
