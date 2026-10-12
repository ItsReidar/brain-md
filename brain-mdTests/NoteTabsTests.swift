//
//  NoteTabsTests.swift
//  brain-mdTests
//

import AppKit
import Foundation
import Testing
@testable import brain_md

/// Removes a file a test moved to the Trash. Give it a unique name, so nothing of yours goes.
func removeFromTrash(named name: String) {
    guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    else { return }
    try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
}

@MainActor
struct NoteTabsTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-tabs-\(UUID().uuidString)")
    private var vaultURL: URL { root.appendingPathComponent("Vault") }

    /// A vault whose "windows" open the way SwiftUI would: a new session showing the note, in front.
    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] {
            try "# \(name)".write(to: vaultURL.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        let vault = VaultManager(customVaultURL: vaultURL)
        openWindows(in: vault)
        return vault
    }

    private func openWindows(in vault: VaultManager) {
        _ = vault.claimSession() // the launch window
        vault.openWindowHandler = { [weak vault] request in
            guard let vault else { return }
            vault.activate(vault.claimSession(loading: request.path))
        }
    }

    private func note(_ vault: VaultManager, _ name: String) throws -> NoteItem {
        try #require(vault.rootItems.first { $0.relativePath == "\(name).md" })
    }

    private func shown(_ vault: VaultManager) -> [String] {
        vault.sessions.map { $0.selectedItem?.displayName ?? "" }
    }

    @Test func aNewTabIsAWindowOfItsOwnAndTheOtherKeepsItsNote() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        #expect(shown(vault) == ["A", "B"])
        #expect(vault.selectedItem?.relativePath == "B.md") // the new tab is in front
        #expect(vault.editorContent == "# B")

        vault.openInNewTab(try note(vault, "A")) // already open: its tab comes to the front
        #expect(shown(vault) == ["A", "B"])
        #expect(vault.editorContent == "# A")
    }

    @Test func aPlainClickReplacesTheNoteInTheFrontTab() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openNote(try note(vault, "A"), inNewTab: false)
        vault.openNote(try note(vault, "B"), inNewTab: true)
        vault.openNote(try note(vault, "C"), inNewTab: false)
        #expect(shown(vault) == ["A", "C"])
    }

    @Test func eachTabKeepsItsOwnUnsavedEdits() async throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        let first = vault.activeSession
        vault.editorContent = "# A edited"
        vault.hasUnsavedChanges = true
        vault.scheduleAutosave(after: 0.05)

        vault.openInNewTab(try note(vault, "B"))
        #expect(vault.editorContent == "# B")
        #expect(first.editorContent == "# A edited") // switching tabs keeps the other tab's edits

        // Auto-save still saves the tab that was typed in, though another tab is in front.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(try String(contentsOf: vaultURL.appendingPathComponent("A.md"), encoding: .utf8) == "# A edited")
        #expect(!first.hasUnsavedChanges)
    }

    @Test func closingATabSavesItAndBringsAnotherToTheFront() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        let second = vault.activeSession
        vault.editorContent = "# B edited"
        vault.hasUnsavedChanges = true

        vault.closeSession(second)
        #expect(try String(contentsOf: vaultURL.appendingPathComponent("B.md"), encoding: .utf8) == "# B edited")
        #expect(shown(vault) == ["A"])
        #expect(vault.selectedItem?.relativePath == "A.md")

        vault.closeSession(vault.activeSession) // the last window: an empty session stays for MCP
        #expect(vault.selectedItem == nil)
        #expect(vault.sessions.count == 1)
    }

    @Test func renamingAndDeletingReachEveryTab() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        let first = vault.activeSession
        vault.openInNewTab(try note(vault, "B"))
        let renamed = "Renamed-\(UUID().uuidString)"
        defer { removeFromTrash(named: renamed + ".md") }
        try vault.renameItem(oldRelativePath: "A.md", newName: renamed)
        #expect(first.selectedItem?.relativePath == renamed + ".md")

        try vault.deleteFile(relativePath: renamed + ".md")
        #expect(first.selectedItem == nil)
        #expect(vault.selectedItem?.relativePath == "B.md")
    }

    @Test func aTranscriptLandsInTheTabShowingItsNote() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(try note(vault, "A"))
        let first = vault.activeSession
        let url = try note(vault, "A").url
        vault.openInNewTab(try note(vault, "B"))
        vault.editNote(at: url) { $0 += "\nline" }
        #expect(first.editorContent == "# A\nline")
        #expect(vault.editorContent == "# B")
    }

    @Test func anUnwrittenNewFileIsTrashedOnlyWhenNoTabShowsIt() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let tag = UUID().uuidString // unique, so only this test's file is removed from the Trash
        let new = root.appendingPathComponent("new-\(tag).md")
        try Data().write(to: new)
        #expect(setxattr(new.path, VaultManager.newFileAttribute, "1", 1, 0, 0) == 0)

        vault.openFileInTab(new) // the launch window is empty: it opens there
        let first = vault.activeSession
        vault.openInNewTab(try note(vault, "A"))
        #expect(FileManager.default.fileExists(atPath: new.path)) // still open in a tab
        vault.closeSession(first)
        #expect(!FileManager.default.fileExists(atPath: new.path))

        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(new.lastPathComponent))
    }

    @Test func filesFromFinderOpenInTabsOfTheirOwn() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        MarkdownFiles.open([vaultURL.appendingPathComponent("A.md"), vaultURL.appendingPathComponent("B.md")], vault: vault)
        #expect(shown(vault) == ["A", "B"])
        MarkdownFiles.open([vaultURL.appendingPathComponent("A.md")], vault: vault) // open already
        #expect(shown(vault) == ["A", "B"])
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
        vault.openFileInTab(outside)
        vault.openInNewTab(try note(vault, "C"))
        vault.focus(vault.sessions[1])
        #expect(shown(vault) == ["A", "outside", "C"])

        try FileManager.default.removeItem(at: vaultURL.appendingPathComponent("C.md")) // gone by next launch
        let relaunched = VaultManager(customVaultURL: vaultURL)
        relaunched.tabsDefaults = defaults
        relaunched.restoreTabs() // at launch, before any window
        openWindows(in: relaunched)
        relaunched.openPendingTabs() // the first window opens the rest
        #expect(shown(relaunched) == ["A", "outside"])
        #expect(relaunched.selectedItem?.isExternal == true) // the tab that was in front
        #expect(relaunched.editorContent == "# Outside")

        // Another vault keeps its own tabs; this one's are untouched.
        let otherURL = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        try "# D".write(to: otherURL.appendingPathComponent("D.md"), atomically: true, encoding: .utf8)
        let other = VaultManager(customVaultURL: otherURL)
        other.tabsDefaults = defaults
        other.restoreTabs()
        #expect(other.selectedItem == nil)
        other.selectNote(byRelativePath: "D.md")
        let again = VaultManager(customVaultURL: vaultURL)
        again.tabsDefaults = defaults
        again.restoreTabs()
        #expect(again.selectedItem?.relativePath == "A.md")
        #expect(again.pendingTabPaths == [outside.resolvingSymlinksInPath().path])
    }

    @Test func quittingKeepsTheTabListAsItWas() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "brainmd-tests-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        vault.tabsDefaults = defaults
        vault.selectNote(try note(vault, "A"))
        vault.openInNewTab(try note(vault, "B"))
        vault.prepareForTermination()
        for session in vault.sessions { vault.closeSession(session) } // the windows close as the app quits
        let saved = defaults.dictionary(forKey: VaultManager.openTabsKey)?[vault.vaultURL.path] as? [String: Any]
        #expect(saved?["tabs"] as? [String] == ["A.md", "B.md"])
    }

    @Test func movingANoteToTheTrashClosesItInEveryTab() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "trash-\(UUID().uuidString).md" // unique, so only this test's file is removed from the Trash
        try "# Gone".write(to: vaultURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        vault.refreshFiles()
        vault.selectNote(byRelativePath: name)
        let first = vault.activeSession
        vault.openInNewTab(try note(vault, "A"))
        vault.focus(first)

        try vault.deleteFile(relativePath: name)
        #expect(!FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent(name).path))
        #expect(first.selectedItem == nil)
        #expect(vault.noteItem(atRelativePath: name) == nil)
        #expect(vault.recentActivities.first?.action == "Moved to Trash")

        removeFromTrash(named: name)
    }

    @Test func commandDeleteTrashesTheNoteUnlessYoureEditingText() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        func open(_ name: String) throws -> String {
            let file = "\(name)-\(UUID().uuidString).md" // unique: it goes to the Trash
            try "# \(name)".write(to: vaultURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
            vault.refreshFiles()
            vault.selectNote(byRelativePath: file)
            return file
        }
        func exists(_ file: String) -> Bool { FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent(file).path) }

        // Nothing focused, or an empty field SwiftUI focused by itself: the note goes.
        let first = try open("First")
        defer { removeFromTrash(named: first) }
        vault.commandDelete(firstResponder: nil)
        #expect(!exists(first))
        let second = try open("Second")
        defer { removeFromTrash(named: second) }
        vault.commandDelete(firstResponder: NSTextView())
        #expect(!exists(second))

        // Typing in a field, or in the note editor: ⌘⌫ deletes text and the note stays.
        let third = try open("Third")
        defer { removeFromTrash(named: third) }
        let field = NSTextView()
        field.string = "search words"
        field.setSelectedRange(NSRange(location: 12, length: 0))
        vault.commandDelete(firstResponder: field)
        #expect(field.string.isEmpty)
        vault.commandDelete(firstResponder: MarkdownNSTextView(frame: .zero))
        #expect(exists(third))
    }

    @Test func failedSidebarOperationsAreShownNotSilent() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        var shown: [String] = []
        vault.errorPresenter = { title, _ in shown.append(title) }

        vault.trash(relativePath: "Missing.md")
        let renamed = vault.reportingErrors("Couldn't Rename") { try vault.renameItem(oldRelativePath: "A.md", newName: "B") }
        let moved = vault.reportingErrors("Couldn't Move") {
            try vault.moveItem(sourceRelativePath: "Missing.md", toDirectoryRelativePath: "")
        }
        #expect(!renamed && !moved) // B.md exists; Missing.md doesn't
        #expect(shown == ["Couldn't Move to Trash", "Couldn't Rename", "Couldn't Move"])
        let logged = vault.recentActivities.prefix(3).allSatisfy(\.isError)
        #expect(logged)

        let ok = vault.reportingErrors("Couldn't Rename") { try vault.renameItem(oldRelativePath: "A.md", newName: "D") }
        #expect(ok)
        #expect(shown.count == 3) // a success shows nothing
    }
}
