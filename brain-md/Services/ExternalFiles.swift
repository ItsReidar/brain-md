//
//  ExternalFiles.swift
//  brain-md
//
//  Markdown files opened from Finder. A file inside the vault opens as the vault note; any other
//  Markdown file opens in the same editor, marked as outside the vault, and saves back to itself.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import os

private let fileLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Files")

extension VaultManager {
    /// Opens a Markdown file: the vault note if it's inside the vault, otherwise the file itself.
    public func openFile(at url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let relativePath = relativePathInVault(url) {
            refreshFiles()
            selectNote(byRelativePath: relativePath)
            if selectedItem?.relativePath == relativePath {
                fileLog.info("Opened a vault note from Finder")
                return
            }
        }
        if hasUnsavedChanges {
            saveCurrentNote()
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            var item = NoteItem(
                name: url.lastPathComponent, relativePath: url.path, url: url, isDirectory: false,
                modifiedAt: modified, size: Int64(content.utf8.count))
            item.isExternal = true
            selectedItem = item
            editorTitle = item.displayName
            editorContent = content
            hasUnsavedChanges = false
            logActivity(action: "Opened File", detail: url.path, isError: false)
            fileLog.info("Opened a file outside the vault from Finder (\(content.utf8.count, privacy: .public) bytes)")
        } catch {
            logActivity(action: "Open Failed", detail: "\(url.lastPathComponent): \(error.localizedDescription)", isError: true)
            fileLog.error("Couldn't open a file from Finder: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Set by the `brain` command on the empty files it creates. Saves write a new file, which drops it.
    static let newFileAttribute = "itsreidar.brain-md.new"

    /// Moves a file the `brain` command created to the Trash if nothing was ever written to it.
    @discardableResult
    func trashIfUnwritten(_ url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0,
              getxattr(url.path, Self.newFileAttribute, nil, 0, 0, 0) >= 0 else { return nil }
        let inVault = relativePathInVault(url) != nil // a trashed path no longer resolves
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            fileLog.error("Couldn't trash an unused new file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if inVault { refreshFiles() }
        logActivity(action: "Trashed Empty File", detail: url.path, isError: false)
        return trashed as URL?
    }

    /// The vault-relative path of `url`, or nil when it's outside the vault.
    func relativePathInVault(_ url: URL) -> String? {
        let root = vaultURL.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    func saveExternalFile(_ item: NoteItem) {
        do {
            try editorContent.write(to: item.url, atomically: true, encoding: .utf8)
            hasUnsavedChanges = false
            logActivity(action: "Updated File", detail: item.url.path, isError: false)
        } catch {
            logActivity(action: "Save Failed", detail: "\(item.url.path): \(error.localizedDescription)", isError: true)
        }
    }

    /// Copies the open outside file, with any unsaved edits, into the vault root and opens the copy.
    /// The original file is left as it was last saved.
    @discardableResult
    public func addExternalFileToVault() throws -> String {
        guard let item = selectedItem, item.isExternal else {
            throw BrainError.invalidPath(path: "The open note is already in the vault.")
        }
        let path = generateUniqueNotePath(baseName: (item.name as NSString).deletingPathExtension)
        let content = editorContent
        hasUnsavedChanges = false // the edits go into the copy, not the original
        try createFile(relativePath: path, content: content)
        return path
    }
}

/// Finder integration: which files brain-md opens, and making it the default Markdown app.
enum MarkdownFiles {
    static let contentType = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText

    static func isMarkdown(_ url: URL) -> Bool {
        url.isFileURL && NoteItem.markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Opens each Markdown file among `urls` in a tab of its own.
    static func open(_ urls: [URL], vault: VaultManager = .shared) {
        for url in urls where isMarkdown(url) {
            vault.openFileInTab(url)
        }
    }

    /// The app Finder opens Markdown files with.
    static var defaultApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: contentType)
    }

    static var isBrainMDDefault: Bool {
        defaultApplicationURL.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to open Markdown files with brain-md; macOS confirms the change with the user.
    static func makeBrainMDDefault() async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: contentType)
    }
}

/// Receives files opened from Finder (double-click, Open With, drag onto the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Takes the "open documents" event before SwiftUI does: SwiftUI would also open (and close) a
    /// window of its own for each file, next to the tab Brain.md opens.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        // A single file arrives as the descriptor itself, several as a list (indexed from 1).
        let urls = list.numberOfItems == 0
            ? [list.fileURLValue].compactMap { $0 }
            : (1...list.numberOfItems).compactMap { list.atIndex($0)?.fileURLValue }
        MarkdownFiles.open(urls)
    }

    /// Runs before the windows close, so the tab list is saved as it was.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        VaultManager.shared.prepareForTermination()
        return .terminateNow
    }

    /// The tab bar's + button.
    @objc func newWindowForTab(_ sender: Any?) {
        VaultManager.shared.openWindowHandler?(NoteWindowRequest(path: nil))
    }
}
