//
//  VaultManager.swift
//  brain-md
//

import Foundation
import SwiftUI
import Combine

// MARK: - Thread-Safe File Monitor

private final class VaultFileMonitor: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var debounceWorkItem: DispatchWorkItem?
    
    nonisolated init() {}
    
    nonisolated func start(url: URL, onChange: @escaping @Sendable () -> Void) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        
        s.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                onChange()
            }
            self.debounceWorkItem = workItem
            self.lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
        s.setCancelHandler {
            close(fd)
        }
        
        lock.lock()
        source = s
        lock.unlock()
        
        s.resume()
    }
    
    nonisolated func stop() {
        lock.lock()
        defer { lock.unlock() }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let s = source {
            s.cancel()
            source = nil
        }
    }
}

// MARK: - Vault Manager

@MainActor
public final class VaultManager: ObservableObject, VaultManaging {
    public static let shared = VaultManager()
    
    @Published public var vaultURL: URL
    @Published public var rootItems: [NoteItem] = []
    @Published public var selectedItem: NoteItem?
    @Published public var editorContent: String = ""
    @Published public var editorTitle: String = ""
    @Published public var searchQuery: String = ""
    @Published public var hasUnsavedChanges: Bool = false
    @Published public var recentActivities: [ActivityLog] = []
    @Published public var totalNotesCount: Int = 0
    @Published public var allTags: [String: Int] = [:]
    @Published public var selectedTag: String? = nil
    @Published public var showingNewNotePrompt: Bool = false
    @Published public var newNotePromptDefaultName: String = ""
    
    private let fileMonitor = VaultFileMonitor()
    private let userDefaultsVaultKey = "brain_md_vault_path"
    
    public init(customVaultURL: URL? = nil) {
        let fileManager = FileManager.default
        let defaultVault: URL
        if let custom = customVaultURL {
            defaultVault = custom
        } else if let savedPath = UserDefaults.standard.string(forKey: userDefaultsVaultKey),
           fileManager.fileExists(atPath: savedPath) {
            defaultVault = URL(fileURLWithPath: savedPath)
        } else {
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
            defaultVault = docs.appendingPathComponent("BrainNotes", isDirectory: true)
        }
        
        self.vaultURL = defaultVault.standardized.resolvingSymlinksInPath()
        setupVaultDirectory()
        refreshFiles()
        startFileWatcher()
    }
    
    deinit {
        fileMonitor.stop()
    }
    
    // MARK: - Security & Path Resolution
    
    public func resolveSecurePath(relativePath: String) throws -> URL {
        let cleanPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty else {
            throw BrainError.invalidPath(path: relativePath)
        }
        
        let targetURL = vaultURL.appendingPathComponent(cleanPath).standardized.resolvingSymlinksInPath()
        let standardVault = vaultURL.standardized.resolvingSymlinksInPath()
        
        guard targetURL.path.hasPrefix(standardVault.path) else {
            throw BrainError.directoryTraversalBlocked(path: relativePath)
        }
        return targetURL
    }
    
    private func relativePath(of fileURL: URL, relativeTo baseURL: URL) -> String {
        let base = baseURL.standardized.resolvingSymlinksInPath().path
        let file = fileURL.standardized.resolvingSymlinksInPath().path
        if file.hasPrefix(base) {
            let suffix = String(file.dropFirst(base.count))
            return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return fileURL.lastPathComponent
    }
    
    // MARK: - Directory Setup & Seed
    
    private func setupVaultDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: vaultURL.path) {
            try? fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            seedDefaultNotes()
        } else {
            let contents = (try? fm.contentsOfDirectory(atPath: vaultURL.path)) ?? []
            let mdFiles = contents.filter { $0.hasSuffix(".md") || $0.hasSuffix(".markdown") }
            if mdFiles.isEmpty {
                seedDefaultNotes()
            }
        }
    }
    
    public static let defaultWelcomeNoteContent: String = """
    ---
    title: Welcome to Brain-md
    tags: [welcome, guide, mcp, mermaid, markdown]
    status: published
    author: Brain-md Team
    date: 2026-09-18
    ---
    # Welcome to Brain-md 🧠

    A fast, native macOS Markdown knowledge base with a built-in **Model Context Protocol (MCP)** server, real-time syntax highlighting across 112 terminal themes, and interactive offline GitHub Flavored Markdown preview.

    > [!TIP]
    > Switch to **Split** mode in the top-right toolbar to view the live theme-aware editor alongside this formatted preview!

    ---

    ## ⚡ Quick Start & Keyboard Shortcuts

    | Action | Shortcut | Description |
    | :--- | :--- | :--- |
    | **New Note** | `⌘N` | Prompt to name and create a new markdown note |
    | **Save Note** | `⌘S` | Save current modifications with toast confirmation |
    | **Settings** | `⌘,` | Change themes, typography, MCP port, & templates |
    | **Search Notes** | `Sidebar` | Instant full-text search across titles and note content |
    | **Tag Filtering** | `Click #tag` | Filter notes in vault by clicking any tag chip |

    ---

    ## 📊 Interactive Mermaid Diagrams

    Brain-md provides full offline **Mermaid.js** diagram rendering. Flowcharts, sequence diagrams, and architecture graphs render directly in your notes.

    ### Architecture Flowchart

    ```mermaid
    graph TD
        User([👤 User / Writer]) <-->|Edit & Preview| UI[💻 Brain-md SwiftUI App]
        UI <-->|File System Watcher| Vault[(📁 Notes Vault)]
        Agent([🤖 AI Agent / Claude / Gemini]) <-->|HTTP SSE :8765 & Stdio| Server[⚡ Built-in MCP Server]
        Server <-->|CRUD Tools & Resources| Vault
    ```

    ### MCP Tool Execution Sequence

    ```mermaid
    sequenceDiagram
        autonumber
        actor Agent as 🤖 AI Assistant
        participant MCP as ⚡ Brain-md Server
        participant Vault as 📁 Vault Manager
        
        Agent->>MCP: tools/call ("search_notes", query: "roadmap")
        MCP->>Vault: Query file index & snippets
        Vault-->>MCP: Matching notes list
        MCP-->>Agent: JSON-RPC Result
        Agent->>MCP: tools/call ("read_note", path: "Roadmap.md")
        MCP->>Vault: Read file content
        Vault-->>MCP: Markdown text
        MCP-->>Agent: Note content returned
    ```

    ---

    ## 🎨 Theme-Aware Markdown Syntax Highlighting

    The raw editor dynamically highlights markdown tokens using your selected terminal palette (choose from **112 dark & light themes** in Settings):

    - **Headings**: `# Title`, `## Subtitle`, `### Section` with scaled visual hierarchy
    - **List Markers**: Unordered bullets (`- `, `* `, `+ `) and numbers (`1. `, `2. `)
    - **Task Checkboxes**: Interactive task items (`[ ]` and `[x]`)
    - **Formatting**: `**bold**`, `*italic*`, `~~strikethrough~~`, and `#tags`
    - **Inline Code**: `` `let brain = BrainMD()` `` with monospace font and subtle background tint

    ---

    ## 💻 Multi-Language Code Blocks

    Code blocks feature syntax highlighting, language badges, and one-click clipboard copying:

    ```swift
    import SwiftUI

    struct BrainGreeting: View {
        let appName: String = "Brain-md"
        
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                Text("Welcome to \\(appName)!")
                    .font(.headline)
            }
        }
    }
    ```

    ```python
    import json
    import httpx

    # Connect to Brain-md local MCP server
    response = httpx.post(
        "http://127.0.0.1:8765/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "list_notes", "arguments": {}}
        }
    )
    print("Vault Notes:", response.json())
    ```

    ---

    ## 📋 Task Management

    Track your workflows with native GitHub task lists:

    - [x] Integrate 112 terminal themes from terminalcolors.com
    - [x] Add live syntax highlighting to raw markdown editor
    - [x] Support offline Mermaid.js diagrams
    - [x] Implement built-in MCP HTTP & Stdio server
    - [ ] Connect your favorite AI assistant to Brain-md

    ---

    ## 💬 GitHub Alerts & Callouts

    > [!NOTE]
    > Notes are stored locally on disk as standard `.md` files. You retain 100% data ownership.

    > [!IMPORTANT]
    > The MCP server supports both HTTP/SSE on port `8765` and standard input/output (`brain-md --stdio`).

    > [!WARNING]
    > Renaming folders will safely update all nested relative note paths in the vault index.

    > [!CAUTION]
    > Deleting a note removes it from disk. Always keep backups of your vault folder.

    ---

    ## 🔌 Connecting Claude Desktop or External Agents

    Add this configuration to `~/Library/Application Support/Claude/claude_desktop_config.json`:

    ```json
    {
      "mcpServers": {
        "brain-md": {
          "url": "http://127.0.0.1:8765/sse"
        }
      }
    }
    ```

    Enjoy writing, organizing, and thinking with your personal AI second brain! 🚀
    """

    public static let defaultIdeasNoteContent: String = """
    ---
    title: Project Ideas
    tags: [ideas, roadmap]
    status: in-progress
    pinned: true
    ---
    # Project Ideas
    
    - [ ] Connect Claude Desktop to local MCP server
    - [ ] Create personal knowledge graph
    - [ ] Automate daily journal summaries
    - [x] Integrate high-contrast syntax highlighting
    - [x] Add GitHub Flavored Markdown alerts and tables
    - [x] Add offline Mermaid JS chart support
    """
    
    private func seedDefaultNotes() {
        try? createFile(relativePath: "Welcome to Brain-md.md", content: Self.defaultWelcomeNoteContent)
        try? createFile(relativePath: "Project Ideas.md", content: Self.defaultIdeasNoteContent)
    }
    
    // MARK: - File System Monitoring
    
    private func startFileWatcher() {
        fileMonitor.start(url: vaultURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshFiles()
            }
        }
    }
    
    public nonisolated func stopFileWatcher() {
        fileMonitor.stop()
    }
    
    // MARK: - File Operations
    
    public func refreshFiles() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultURL.path) else {
            rootItems = []
            totalNotesCount = 0
            allTags = [:]
            return
        }
        
        var count = 0
        rootItems = scanDirectory(url: vaultURL, base: vaultURL, noteCount: &count)
        totalNotesCount = count
        
        // Aggregate vault-wide tag dictionary
        var tagCounts: [String: Int] = [:]
        func collectTags(from items: [NoteItem]) {
            for item in items {
                if item.isDirectory, let children = item.children {
                    collectTags(from: children)
                } else {
                    for tag in item.tags {
                        tagCounts[tag, default: 0] += 1
                    }
                }
            }
        }
        collectTags(from: rootItems)
        allTags = tagCounts
        
        // Invalidate selected tag if no longer exists in vault
        if let currentTag = selectedTag, tagCounts[currentTag] == nil {
            selectedTag = nil
        }
        
        if let current = selectedItem {
            let stillExists = fm.fileExists(atPath: current.url.path)
            if !stillExists {
                selectedItem = nil
                editorContent = ""
                editorTitle = ""
            }
        }
    }
    
    private func scanDirectory(url: URL, base: URL, noteCount: inout Int) -> [NoteItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var items: [NoteItem] = []
        
        for file in contents {
            let resourceValues = try? file.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate ?? Date()
            let size = resourceValues?.fileSize ?? 0
            
            let relPath = relativePath(of: file, relativeTo: base)
            
            if isDir {
                let children = scanDirectory(url: file, base: base, noteCount: &noteCount)
                items.append(NoteItem(
                    name: file.lastPathComponent,
                    relativePath: relPath,
                    url: file,
                    isDirectory: true,
                    children: children,
                    modifiedAt: modDate,
                    size: 0
                ))
            } else if file.pathExtension.lowercased() == "md" || file.pathExtension.lowercased() == "markdown" || file.pathExtension.lowercased() == "txt" {
                noteCount += 1
                
                // Parse frontmatter tags if Markdown file
                var noteTags: [String] = []
                if file.pathExtension.lowercased() == "md" || file.pathExtension.lowercased() == "markdown" {
                    if let content = try? String(contentsOf: file, encoding: .utf8) {
                        let (fm, _) = FrontmatterParser.parse(content)
                        if let parsedFM = fm {
                            noteTags = parsedFM.tags
                        }
                    }
                }
                
                items.append(NoteItem(
                    name: file.deletingPathExtension().lastPathComponent,
                    relativePath: relPath,
                    url: file,
                    isDirectory: false,
                    children: nil,
                    modifiedAt: modDate,
                    size: Int64(size),
                    tags: noteTags
                ))
            }
        }
        
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    
    public func selectNote(_ item: NoteItem) {
        guard !item.isDirectory else { return }
        if hasUnsavedChanges {
            saveCurrentNote()
        }
        selectedItem = item
        editorTitle = item.name
        do {
            editorContent = try readFile(relativePath: item.relativePath)
            hasUnsavedChanges = false
        } catch {
            logActivity(action: "Read Failed", detail: error.localizedDescription, isError: true)
        }
    }
    
    public func selectNote(byRelativePath path: String) {
        func findIn(items: [NoteItem]) -> NoteItem? {
            for item in items {
                if item.relativePath == path { return item }
                if let children = item.children, let found = findIn(items: children) {
                    return found
                }
            }
            return nil
        }
        if let item = findIn(items: rootItems) {
            selectNote(item)
        }
    }
    
    public func generateUniqueNotePath(baseName: String = "Untitled") -> String {
        let cleanBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanBase.isEmpty ? "Untitled" : cleanBase
        let candidate = "\(name).md"
        let fileURL = vaultURL.appendingPathComponent(candidate)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return candidate
        }
        
        var counter = 1
        while true {
            let candidate = "\(name) \(counter).md"
            let fileURL = vaultURL.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                return candidate
            }
            counter += 1
        }
    }
    
    public func saveCurrentNote() {
        guard let current = selectedItem, !current.isDirectory else { return }
        do {
            try writeFile(relativePath: current.relativePath, content: editorContent)
            hasUnsavedChanges = false
        } catch {
            logActivity(action: "Save Failed", detail: error.localizedDescription, isError: true)
        }
    }
    
    public func promptNewNote() {
        let defaultTitle = NoteTemplateEngine.resolveTitle(from: .standard)
        newNotePromptDefaultName = generateUniqueNotePath(baseName: defaultTitle)
        showingNewNotePrompt = true
    }
    
    public func createNote(named name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrainError.invalidPath(path: "Note name cannot be empty.")
        }
        
        var finalName = trimmed
        if !finalName.lowercased().hasSuffix(".md") && !finalName.contains(".") {
            finalName += ".md"
        }
        
        let title = (finalName as NSString).deletingPathExtension
        let content = NoteTemplateEngine.resolveContent(for: title, from: .standard)
        try createFile(relativePath: finalName, content: content)
        return finalName
    }
    
    public func createNoteFromTemplate() throws -> String {
        let baseTitle = NoteTemplateEngine.resolveTitle(from: .standard)
        let notePath = generateUniqueNotePath(baseName: baseTitle)
        let noteTitle = (notePath as NSString).deletingPathExtension
        let content = NoteTemplateEngine.resolveContent(for: noteTitle, from: .standard)
        try createFile(relativePath: notePath, content: content)
        return notePath
    }
    
    // MARK: - CRUD API (Protocol Implementation)
    
    public func listFiles(relativeSubdirectory: String? = nil) throws -> [NoteItem] {
        var base = vaultURL
        if let sub = relativeSubdirectory, !sub.isEmpty {
            base = try resolveSecurePath(relativePath: sub)
        }
        var count = 0
        return scanDirectory(url: base, base: vaultURL, noteCount: &count)
    }
    
    public func readFile(relativePath: String) throws -> String {
        let fileURL = try resolveSecurePath(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrainError.fileNotFound(path: relativePath)
        }
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw BrainError.readFailed(path: relativePath, reason: error.localizedDescription)
        }
    }
    
    public func createFile(relativePath: String, content: String) throws {
        var cleanPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !cleanPath.hasSuffix(".md") && !cleanPath.contains(".") {
            cleanPath += ".md"
        }
        let fileURL = try resolveSecurePath(relativePath: cleanPath)
        let parentDir = fileURL.deletingLastPathComponent()
        
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw BrainError.directoryCreationFailed(path: parentDir.path)
        }
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            refreshFiles()
            selectNote(byRelativePath: cleanPath)
            logActivity(action: "Created Note", detail: cleanPath, isError: false)
        } catch {
            throw BrainError.writeFailed(path: cleanPath, reason: error.localizedDescription)
        }
    }
    
    public func writeFile(relativePath: String, content: String) throws {
        let fileURL = try resolveSecurePath(relativePath: relativePath)
        let parentDir = fileURL.deletingLastPathComponent()
        
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw BrainError.directoryCreationFailed(path: parentDir.path)
        }
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            refreshFiles()
            logActivity(action: "Updated Note", detail: relativePath, isError: false)
        } catch {
            throw BrainError.writeFailed(path: relativePath, reason: error.localizedDescription)
        }
    }
    
    public func appendFile(relativePath: String, contentToAppend: String) throws {
        let fileURL = try resolveSecurePath(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrainError.fileNotFound(path: relativePath)
        }
        
        do {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            if let data = contentToAppend.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
            refreshFiles()
            logActivity(action: "Appended Note", detail: relativePath, isError: false)
        } catch {
            throw BrainError.writeFailed(path: relativePath, reason: error.localizedDescription)
        }
    }
    
    public func deleteFile(relativePath: String) throws {
        let fileURL = try resolveSecurePath(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrainError.fileNotFound(path: relativePath)
        }
        
        do {
            try FileManager.default.removeItem(at: fileURL)
            if selectedItem?.relativePath == relativePath {
                selectedItem = nil
                editorContent = ""
                editorTitle = ""
            }
            refreshFiles()
            logActivity(action: "Deleted Note", detail: relativePath, isError: false)
        } catch {
            throw BrainError.deleteFailed(path: relativePath, reason: error.localizedDescription)
        }
    }
    
    public func createFolder(relativePath: String) throws {
        let dirURL = try resolveSecurePath(relativePath: relativePath)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            refreshFiles()
            logActivity(action: "Created Folder", detail: relativePath, isError: false)
        } catch {
            throw BrainError.directoryCreationFailed(path: relativePath)
        }
    }
    
    public func createDirectory(relativePath: String) throws {
        try createFolder(relativePath: relativePath)
    }
    
    public func renameItem(oldRelativePath: String, newName: String) throws {
        let oldURL = try resolveSecurePath(relativePath: oldRelativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: oldURL.path, isDirectory: &isDir) else {
            throw BrainError.fileNotFound(path: oldRelativePath)
        }
        
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedName.contains("/"), !trimmedName.contains("\\") else {
            throw BrainError.invalidPath(path: newName)
        }
        
        var targetName = trimmedName
        if !isDir.boolValue {
            let oldExt = oldURL.pathExtension
            let supportedExtensions = ["md", "markdown", "txt"]
            let hasSupportedExt = supportedExtensions.contains { ext in
                targetName.lowercased().hasSuffix(".\(ext)")
            }
            if !hasSupportedExt && !oldExt.isEmpty {
                targetName = "\(targetName).\(oldExt)"
            }
        }
        
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(targetName)
        
        // Prevent collision if target already exists with a different path
        if newURL.standardizedFileURL.path != oldURL.standardizedFileURL.path && FileManager.default.fileExists(atPath: newURL.path) {
            throw BrainError.writeFailed(path: oldRelativePath, reason: "An item named '\(targetName)' already exists.")
        }
        
        // If unchanged, simply return
        if newURL.standardizedFileURL.path == oldURL.standardizedFileURL.path {
            return
        }
        
        // Flush unsaved changes if this note is currently open
        if selectedItem?.relativePath == oldRelativePath && hasUnsavedChanges {
            saveCurrentNote()
        }
        
        let selectedWasInside = isDir.boolValue && selectedItem?.relativePath.hasPrefix(oldRelativePath + "/") == true
        let oldSelectedPath = selectedItem?.relativePath
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let newRelPath = relativePath(of: newURL, relativeTo: vaultURL)
            refreshFiles()
            
            if !isDir.boolValue {
                selectNote(byRelativePath: newRelPath)
            } else if selectedWasInside, let oldSelected = oldSelectedPath {
                let suffix = String(oldSelected.dropFirst(oldRelativePath.count))
                let updatedSelected = newRelPath + suffix
                selectNote(byRelativePath: updatedSelected)
            }
            logActivity(action: "Renamed", detail: "\(oldRelativePath) -> \(targetName)", isError: false)
        } catch {
            throw BrainError.writeFailed(path: oldRelativePath, reason: error.localizedDescription)
        }
    }
    
    public func moveItem(sourceRelativePath: String, toDirectoryRelativePath: String) throws {
        let sourceURL = try resolveSecurePath(relativePath: sourceRelativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BrainError.fileNotFound(path: sourceRelativePath)
        }
        
        let cleanDestDir = toDirectoryRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let destDirURL: URL
        if cleanDestDir.isEmpty {
            destDirURL = vaultURL
        } else {
            destDirURL = try resolveSecurePath(relativePath: cleanDestDir)
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destDirURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw BrainError.directoryCreationFailed(path: cleanDestDir)
        }
        
        let standardSource = sourceURL.standardizedFileURL.path
        let standardDest = destDirURL.standardizedFileURL.path
        if standardDest == standardSource || standardDest.hasPrefix(standardSource + "/") {
            throw BrainError.invalidPath(path: "Cannot move an item into itself or its own subdirectories.")
        }
        
        let fileName = sourceURL.lastPathComponent
        let targetInitialURL = destDirURL.appendingPathComponent(fileName)
        
        // If already in target directory, nothing to do
        if sourceURL.deletingLastPathComponent().standardizedFileURL.path == destDirURL.standardizedFileURL.path {
            return
        }
        
        var targetURL = targetInitialURL
        let fm = FileManager.default
        if fm.fileExists(atPath: targetURL.path) {
            let isSourceDir = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isSourceDir {
                let base = fileName
                var counter = 1
                while fm.fileExists(atPath: targetURL.path) {
                    targetURL = destDirURL.appendingPathComponent("\(base) \(counter)")
                    counter += 1
                }
            } else {
                let ext = (fileName as NSString).pathExtension
                let base = (fileName as NSString).deletingPathExtension
                var counter = 1
                while fm.fileExists(atPath: targetURL.path) {
                    let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    targetURL = destDirURL.appendingPathComponent(candidate)
                    counter += 1
                }
            }
        }
        
        if hasUnsavedChanges {
            saveCurrentNote()
        }
        
        do {
            let isSourceDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let selectedWasInside = selectedItem?.relativePath.hasPrefix(sourceRelativePath + "/") == true
            let oldSelectedPath = selectedItem?.relativePath
            
            try fm.moveItem(at: sourceURL, to: targetURL)
            let newRelPath = relativePath(of: targetURL, relativeTo: vaultURL)
            refreshFiles()
            
            if !isSourceDirectory {
                selectNote(byRelativePath: newRelPath)
            } else if selectedWasInside, let oldSelected = oldSelectedPath {
                let suffix = String(oldSelected.dropFirst(sourceRelativePath.count))
                let updatedSelected = newRelPath + suffix
                selectNote(byRelativePath: updatedSelected)
            }
            
            logActivity(
                action: "Moved Item",
                detail: "\(sourceRelativePath) -> \(cleanDestDir.isEmpty ? "Root" : cleanDestDir)",
                isError: false
            )
        } catch {
            logActivity(action: "Move Failed", detail: error.localizedDescription, isError: true)
            throw BrainError.writeFailed(path: sourceRelativePath, reason: error.localizedDescription)
        }
    }
    
    public func moveItem(sourceRelativePath: String, intoContainerOf item: NoteItem) throws {
        if item.isDirectory {
            try moveItem(sourceRelativePath: sourceRelativePath, toDirectoryRelativePath: item.relativePath)
        } else {
            let parentDir = (item.relativePath as NSString).deletingLastPathComponent
            try moveItem(sourceRelativePath: sourceRelativePath, toDirectoryRelativePath: parentDir)
        }
    }
    
    // MARK: - Tag Queries
    
    public func getNotes(taggedWith tag: String) -> [NoteItem] {
        let cleanTag = FrontmatterParser.cleanTag(tag).lowercased()
        guard !cleanTag.isEmpty else { return [] }
        
        var matching: [NoteItem] = []
        func collectMatching(from items: [NoteItem]) {
            for item in items {
                if item.isDirectory, let children = item.children {
                    collectMatching(from: children)
                } else if item.tags.contains(where: { $0.lowercased() == cleanTag }) {
                    matching.append(item)
                }
            }
        }
        collectMatching(from: rootItems)
        return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    
    // MARK: - Search Engine
    
    public func searchNotes(query: String) -> [NoteSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        var targetQuery = trimmed.lowercased()
        var isTagOnly = false
        if targetQuery.hasPrefix("#") {
            targetQuery = String(targetQuery.dropFirst())
            isTagOnly = true
        } else if targetQuery.hasPrefix("tag:") {
            targetQuery = String(targetQuery.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            isTagOnly = true
        }
        
        var results: [NoteSearchResult] = []
        searchRecursive(directory: vaultURL, base: vaultURL, query: targetQuery, isTagOnly: isTagOnly, results: &results)
        return results
    }
    
    private func searchRecursive(directory: URL, base: URL, query: String, isTagOnly: Bool, results: inout [NoteSearchResult]) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        for file in files {
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                searchRecursive(directory: file, base: base, query: query, isTagOnly: isTagOnly, results: &results)
            } else if file.pathExtension.lowercased() == "md" || file.pathExtension.lowercased() == "markdown" || file.pathExtension.lowercased() == "txt" {
                let relPath = relativePath(of: file, relativeTo: base)
                let title = file.deletingPathExtension().lastPathComponent
                let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                
                let (fm, _) = FrontmatterParser.parse(content)
                let noteTags = fm?.tags ?? []
                let tagMatches = noteTags.contains(where: { $0.lowercased().contains(query) })
                
                if isTagOnly {
                    if tagMatches {
                        results.append(NoteSearchResult(
                            relativePath: relPath,
                            title: title,
                            snippet: "Tags: " + noteTags.map { "#\($0)" }.joined(separator: ", ")
                        ))
                    }
                } else {
                    let titleMatches = title.lowercased().contains(query)
                    let contentMatches = content.lowercased().contains(query)
                    
                    if titleMatches || contentMatches || tagMatches {
                        var snippet = ""
                        if tagMatches && !contentMatches && !titleMatches {
                            snippet = "Tags: " + noteTags.map { "#\($0)" }.joined(separator: ", ")
                        } else if let range = content.range(of: query, options: .caseInsensitive) {
                            let start = content.index(range.lowerBound, offsetBy: -30, limitedBy: content.startIndex) ?? content.startIndex
                            let end = content.index(range.upperBound, offsetBy: 60, limitedBy: content.endIndex) ?? content.endIndex
                            snippet = "..." + content[start..<end].replacingOccurrences(of: "\n", with: " ") + "..."
                        }
                        results.append(NoteSearchResult(
                            relativePath: relPath,
                            title: title,
                            snippet: snippet
                        ))
                    }
                }
            }
        }
    }
    
    public func getAllNotePaths() -> [String] {
        var paths: [String] = []
        collectNotePaths(in: rootItems, paths: &paths)
        return paths
    }
    
    private func collectNotePaths(in items: [NoteItem], paths: inout [String]) {
        for item in items {
            if item.isDirectory, let children = item.children {
                collectNotePaths(in: children, paths: &paths)
            } else if !item.isDirectory {
                paths.append(item.relativePath)
            }
        }
    }
    
    public func getStats() -> [String: AnyCodableValue] {
        let totalFiles = getAllNotePaths().count
        return [
            "vaultPath": .string(vaultURL.path),
            "totalNotes": .int(totalFiles),
            "selectedNote": .string(selectedItem?.relativePath ?? ""),
            "hasUnsavedChanges": .bool(hasUnsavedChanges)
        ]
    }
    
    public func setVaultURL(_ newURL: URL) {
        stopFileWatcher()
        vaultURL = newURL.standardized.resolvingSymlinksInPath()
        UserDefaults.standard.set(vaultURL.path, forKey: userDefaultsVaultKey)
        selectedItem = nil
        editorContent = ""
        editorTitle = ""
        refreshFiles()
        startFileWatcher()
        logActivity(action: "Switched Vault", detail: vaultURL.path, isError: false)
    }
    
    public func logActivity(action: String, detail: String, isError: Bool) {
        let entry = ActivityLog(action: action, detail: detail, isError: isError)
        recentActivities.insert(entry, at: 0)
        if recentActivities.count > 50 {
            recentActivities.removeLast()
        }
    }
}
