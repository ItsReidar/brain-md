//
//  NoteTabsTests.swift
//  brain-mdTests
//

import AppKit
import SwiftUI
import Testing
@testable import brain_md

@MainActor
struct NoteTabsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-tabs-\(UUID().uuidString)")
    private var vaultURL: URL { root.appendingPathComponent("Vault") }

    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] {
            try "# \(name)".write(to: vaultURL.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        let vault = VaultManager(customVaultURL: vaultURL)
        vault.refreshFiles()
        return vault
    }

    private func note(_ vault: VaultManager, _ name: String) throws -> NoteItem {
        try #require(vault.rootItems.first { $0.relativePath == "\(name).md" })
    }

    private func names(_ vault: VaultManager) -> [String] { vault.tabs.map(\.displayName) }

    @Test func aNewTabKeepsTheOtherNoteOpenAndIsNamedAfterItsNote() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        #expect(names(vault) == ["A", "B"])
        #expect(vault.selectedItem?.relativePath == "B.md")
        #expect(vault.editorContent == "# B")

        vault.openInNewTab(try note(vault, "A")) // already open: switch to it
        #expect(names(vault) == ["A", "B"])
        #expect(vault.editorContent == "# A")
    }

    @Test func pickingANoteNormallyReplacesTheActiveTab() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        vault.selectNote(try note(vault, "C"))
        #expect(names(vault) == ["A", "C"])
    }

    @Test func switchingTabsSavesEditsAndClosingShowsTheNextTab() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        vault.openInNewTab(try note(vault, "C"))
        vault.showTab(vault.tabs[1])
        vault.editorContent = "# B edited"
        vault.hasUnsavedChanges = true
        vault.showTab(vault.tabs[0])
        #expect(try String(contentsOf: vaultURL.appendingPathComponent("B.md"), encoding: .utf8) == "# B edited")

        vault.closeTab(vault.tabs[0]) // the active one: the next tab takes its place
        #expect(names(vault) == ["B", "C"])
        #expect(vault.selectedItem?.relativePath == "B.md")
        vault.closeTab(vault.tabs[1]) // a background tab
        #expect(names(vault) == ["B"])
        #expect(vault.selectedItem?.relativePath == "B.md")
        vault.closeTab(vault.tabs[0])
        #expect(vault.tabs.isEmpty)
        #expect(vault.selectedItem == nil)
        #expect(vault.editorContent.isEmpty)
    }

    @Test func aTabWhoseNoteWasDeletedIsDropped() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        try FileManager.default.removeItem(at: vaultURL.appendingPathComponent("A.md"))
        vault.refreshFiles()
        vault.showTab(vault.tabs[0])
        #expect(names(vault) == ["B"])
        #expect(vault.selectedItem?.relativePath == "B.md")
    }

    @Test func anUnwrittenNewFileIsTrashedOnlyWhenItsTabCloses() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = UUID().uuidString // unique, so only this test's file is removed from the Trash
        let new = root.appendingPathComponent("new-\(tag).md")
        try Data().write(to: new)
        #expect(setxattr(new.path, VaultManager.newFileAttribute, "1", 1, 0, 0) == 0)

        vault.openFile(at: new)
        vault.openInNewTab(try note(vault, "A"))
        #expect(FileManager.default.fileExists(atPath: new.path)) // still open in a tab
        vault.showTab(vault.tabs[0])
        #expect(vault.selectedItem?.isExternal == true)
        vault.closeTab(vault.tabs[0])
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(names(vault) == ["A"])

        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(new.lastPathComponent))
    }

    @Test func commandWClosesTheActiveTabInTheEditorWindow() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CloseTabShortcut(vault: vault))
        window.layoutIfNeeded()
        let commandW = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: commandW)) // handled here, so the menu's Close never sees it
        #expect(names(vault) == ["A"])
        #expect(vault.selectedItem?.relativePath == "A.md")
    }

    @Test func openTabsComeBackAfterARelaunch() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "brainmd-tests-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let outside = root.appendingPathComponent("outside.md")
        try "# Outside".write(to: outside, atomically: true, encoding: .utf8)

        vault.tabsDefaults = defaults
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        vault.openFile(at: outside) // replaces B's tab
        vault.openInNewTab(try note(vault, "C"))
        vault.showTab(vault.tabs[1])
        #expect(names(vault) == ["A", "outside", "C"])

        try FileManager.default.removeItem(at: vaultURL.appendingPathComponent("C.md")) // gone by next launch
        let relaunched = VaultManager(customVaultURL: vaultURL)
        relaunched.tabsDefaults = defaults
        relaunched.restoreTabs()
        #expect(names(relaunched) == ["A", "outside"])
        #expect(relaunched.selectedItem?.isExternal == true)
        #expect(relaunched.editorContent == "# Outside")

        // Another vault keeps its own tabs; this one's are untouched.
        let otherURL = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        try "# D".write(to: otherURL.appendingPathComponent("D.md"), atomically: true, encoding: .utf8)
        let other = VaultManager(customVaultURL: otherURL)
        other.tabsDefaults = defaults
        other.restoreTabs()
        #expect(other.tabs.isEmpty)
        other.selectNote(byRelativePath: "D.md")
        let again = VaultManager(customVaultURL: vaultURL)
        again.tabsDefaults = defaults
        again.restoreTabs()
        #expect(names(again) == ["A", "outside"])
    }

    @Test func withoutDefaultsNothingIsRemembered() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.restoreTabs() // no defaults: a no-op
        #expect(names(vault) == ["A"])
    }
}
