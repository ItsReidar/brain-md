//
//  NoteTabs.swift
//  brain-md
//
//  Notes in native macOS tabs. Every tab is a window with its own EditorSession; VaultManager's
//  editor properties (`selectedItem`, `editorContent`, …) act on the frontmost one, `activeSession`.
//

import AppKit
import Combine
import Foundation
import os

private let tabLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Tabs")

extension VaultManager {
    // MARK: - Sessions

    /// Runs `body` with the editor properties pointing at `session` instead of the frontmost one.
    func perform<T>(on session: EditorSession, _ body: () throws -> T) rethrows -> T {
        let previous = editingOverride
        editingOverride = session
        defer { editingOverride = previous }
        return try body()
    }

    func register(_ session: EditorSession) {
        session.onNoteChange = { [weak self, weak session] old in
            guard let self, let session else { return }
            self.noteChanged(in: session, from: old)
        }
        sessions.append(session)
    }

    /// The session for a new window: the one made at launch (with the restored note) if no window
    /// has it yet, otherwise a new one showing `path`.
    func claimSession(loading path: String? = nil) -> EditorSession {
        if let unclaimed = sessions.first(where: { !$0.isClaimed }) {
            unclaimed.isClaimed = true
            if let path { load(path, in: unclaimed) }
            return unclaimed
        }
        let session = EditorSession()
        session.isClaimed = true
        register(session)
        if let path { load(path, in: session) }
        return session
    }

    /// Links a session to its window, before the window is first shown: the window opens as a tab,
    /// and closing it closes the session.
    func attach(_ session: EditorSession, to window: NSWindow) {
        guard session.window !== window else { return }
        session.window = window
        window.tabbingMode = .preferred
        session.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak session] _ in
            MainActor.assumeIsolated {
                guard let self, let session else { return }
                self.closeSession(session)
            }
        }
        if pendingActivePath != nil, sessions.allSatisfy({ $0.window != nil }) {
            // The last restored tab is on screen; bring back the one that was in front.
            DispatchQueue.main.async { self.focusPendingActive() }
        }
    }

    /// Makes `session` the frontmost one: called when its window becomes active.
    func activate(_ session: EditorSession) {
        guard activeSession !== session, sessions.contains(where: { $0 === session }) else { return }
        activeSession = session
        tabLog.info("Front tab changed: \(self.sessions.count, privacy: .public) windows, \(session.window?.tabbedWindows?.count ?? 1, privacy: .public) tabs in the front one")
        saveTabs()
    }

    /// A window closed: saves its note, and trashes it if `brain` created it and it stayed empty.
    func closeSession(_ session: EditorSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        perform(on: session) { if hasUnsavedChanges { saveCurrentNote() } }
        session.autosaveTask?.cancel()
        if let observer = session.closeObserver { NotificationCenter.default.removeObserver(observer) }
        session.closeObserver = nil
        sessions.removeAll { $0 === session }
        if let url = session.selectedItem?.url, self.session(showing: url) == nil { trashIfUnwritten(url) }
        if activeSession === session {
            // The last window closed: keep an empty session for MCP and the next window.
            activeSession = sessions.last ?? {
                let empty = EditorSession()
                register(empty)
                return empty
            }()
        }
        saveTabs()
    }

    /// Closes every window but the frontmost one (when switching vaults).
    func closeOtherSessions() {
        for session in sessions where session !== activeSession {
            if let window = session.window { window.close() } else { closeSession(session) }
        }
    }

    /// The session showing `url`, the frontmost one first.
    func session(showing url: URL) -> EditorSession? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return ([activeSession] + sessions).first {
            $0.selectedItem?.url.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    func saveAllNotes() {
        for session in sessions where session.hasUnsavedChanges {
            perform(on: session) { saveCurrentNote() }
        }
    }

    /// Each window's note path, taken before a rename or move.
    func notesShown() -> [(EditorSession, String)] {
        sessions.compactMap { session in session.selectedItem.map { (session, $0.relativePath) } }
    }

    /// Points every window that showed `old` (or a note inside the folder `old`) at its new path.
    func follow(_ shown: [(EditorSession, String)], from old: String, to new: String) {
        for (session, path) in shown where path == old || path.hasPrefix(old + "/") {
            perform(on: session) { selectNote(byRelativePath: new + path.dropFirst(old.count)) }
        }
    }

    /// Shows a vault-relative path, or an absolute path outside the vault, in `session`.
    func load(_ path: String, in session: EditorSession) {
        perform(on: session) {
            if path.hasPrefix("/") {
                openFile(at: URL(fileURLWithPath: path))
            } else {
                selectNote(byRelativePath: path)
            }
        }
    }

    /// Called whenever a window's note changes.
    func noteChanged(in session: EditorSession, from old: NoteItem?) {
        if session === activeSession { objectWillChange.send() }
        if let old, self.session(showing: old.url) == nil { trashIfUnwritten(old.url) }
        saveTabs()
    }

    // MARK: - Opening notes

    /// A click on a note in a list: ⌘-click opens it in a new tab, a plain click in the current one.
    public func openNote(_ item: NoteItem, inNewTab: Bool = NSEvent.modifierFlags.contains(.command)) {
        if inNewTab, item.isMarkdown {
            openInNewTab(item)
        } else {
            selectNote(item)
        }
    }

    /// Opens `item` in a new tab, or brings its tab to the front if it's already open.
    public func openInNewTab(_ item: NoteItem) {
        openInNewTab(path: item.relativePath, url: item.url)
    }

    /// Opens a file from Finder or the `brain` command: in its tab if it's open, in the frontmost
    /// window if that's empty, otherwise in a new tab.
    func openFileInTab(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if session(showing: url) == nil, activeSession.selectedItem == nil {
            perform(on: activeSession) { openFile(at: url) }
            return
        }
        openInNewTab(path: relativePathInVault(url) ?? url.path, url: url)
    }

    private func openInNewTab(path: String, url: URL) {
        if let open = session(showing: url) {
            focus(open)
        } else if let openWindowHandler {
            openWindowHandler(NoteWindowRequest(path: path))
        } else {
            load(path, in: activeSession) // no windows (headless): show it in place
        }
    }

    func focus(_ session: EditorSession) {
        activate(session)
        session.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Remembering tabs between launches

    /// `[vault path: ["tabs": [path], "active": path]]`. Vault notes are stored by their vault-relative
    /// path, files outside the vault by their absolute path.
    static let openTabsKey = "open_tabs"

    func saveTabs() {
        guard let tabsDefaults, !isTerminating else { return }
        var ordered = sessions
        // The tab bar's order, with any windows outside the tab group after it.
        if let windows = activeSession.window?.tabGroup?.windows {
            let inGroup = windows.compactMap { window in sessions.first { $0.window === window } }
            ordered = inGroup + sessions.filter { session in !inGroup.contains { $0 === session } }
        }
        var entry: [String: Any] = ["tabs": ordered.compactMap { $0.selectedItem?.relativePath }]
        if let active = activeSession.selectedItem?.relativePath { entry["active"] = active }
        var saved = tabsDefaults.dictionary(forKey: Self.openTabsKey) ?? [:]
        saved[vaultURL.path] = entry
        tabsDefaults.set(saved, forKey: Self.openTabsKey)
    }

    /// Shows the first tab this vault had open last time in the frontmost window; the others open
    /// with `openPendingTabs()` once a window can open windows. Notes that are gone are skipped.
    func restoreTabs() {
        guard let entry = tabsDefaults?.dictionary(forKey: Self.openTabsKey)?[vaultURL.path] as? [String: Any],
              let paths = entry["tabs"] as? [String] else { return }
        let existing = paths.filter { path in
            path.hasPrefix("/") ? FileManager.default.fileExists(atPath: path) : noteItem(atRelativePath: path) != nil
        }
        guard let first = existing.first else { return }
        load(first, in: activeSession)
        pendingTabPaths = Array(existing.dropFirst())
        pendingActivePath = entry["active"] as? String
        openPendingTabs()
    }

    func openPendingTabs() {
        guard let openWindowHandler else { return }
        let paths = pendingTabPaths
        pendingTabPaths = []
        for path in paths { openWindowHandler(NoteWindowRequest(path: path)) }
        focusPendingActive()
    }

    func focusPendingActive() {
        guard let path = pendingActivePath,
              let session = sessions.first(where: { $0.selectedItem?.relativePath == path }) else { return }
        focus(session)
        if sessions.allSatisfy({ $0.window != nil }) { pendingActivePath = nil }
    }

    /// Before quitting: saves every window, keeps the tab list as it is, and trashes notes the
    /// `brain` command created that are still empty.
    func prepareForTermination() {
        saveTabs()
        isTerminating = true
        saveAllNotes()
        for session in sessions {
            if let url = session.selectedItem?.url { trashIfUnwritten(url) }
        }
    }
}
