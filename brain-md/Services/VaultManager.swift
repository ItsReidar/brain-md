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
    public static let shared: VaultManager = {
        let vault = VaultManager()
        vault.tabsDefaults = .standard
        vault.errorPresenter = { title, message in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        vault.confirmPresenter = { title, message, button, done in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: button).hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
            } else {
                done(alert.runModal() == .alertFirstButtonReturn)
            }
        }
        vault.restoreTabs()
        return vault
    }()
    
    @Published public var vaultURL: URL
    @Published public var rootItems: [NoteItem] = []

    // MARK: Editor windows (see NoteTabs.swift)

    /// Every open editor window's session, the frontmost one included.
    var sessions: [EditorSession] = []
    /// The frontmost editor window's session: the note MCP, AI Chat and the menus act on.
    @Published public internal(set) var activeSession = EditorSession()
    /// Set while an operation targets a session that isn't the frontmost one.
    var editingOverride: EditorSession?
    var editing: EditorSession { editingOverride ?? activeSession }
    /// Where the open tabs are remembered between launches; nil (as in tests) remembers nothing.
    var tabsDefaults: UserDefaults?
    /// Shows a failed operation to the user (an alert sheet); nil, as in tests, only logs it.
    var errorPresenter: ((_ title: String, _ message: String) -> Void)?
    /// Asks the user to confirm a destructive action (an alert sheet with a destructive button).
    var confirmPresenter: ((_ title: String, _ message: String, _ button: String, _ done: @escaping (Bool) -> Void) -> Void)?
    /// Opens a note window; set by the first window, since only views can open windows.
    var openWindowHandler: ((NoteWindowRequest) -> Void)?
    var pendingTabPaths: [String] = []
    var pendingActivePath: String?
    var isTerminating = false

    public var selectedItem: NoteItem? {
        get { editing.selectedItem }
        set { editing.selectedItem = newValue }
    }
    public var editorContent: String {
        get { editing.editorContent }
        set { editing.editorContent = newValue }
    }
    public var editorTitle: String {
        get { editing.editorTitle }
        set { editing.editorTitle = newValue }
    }
    public var hasUnsavedChanges: Bool {
        get { editing.hasUnsavedChanges }
        set { editing.hasUnsavedChanges = newValue }
    }
    @Published public var searchQuery: String = ""
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
        register(activeSession)
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
        
        for session in sessions {
            if let current = session.selectedItem, !fm.fileExists(atPath: current.url.path) {
                session.selectedItem = nil
                session.editorContent = ""
                session.editorTitle = ""
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
            } else if !file.lastPathComponent.hasPrefix(".") && !file.pathExtension.isEmpty {
                // Non-markdown attachment (images, pdfs, media, etc.)
                items.append(NoteItem(
                    name: file.lastPathComponent,
                    relativePath: relPath,
                    url: file,
                    isDirectory: false,
                    children: nil,
                    modifiedAt: modDate,
                    size: Int64(size),
                    tags: []
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
        editorTitle = item.displayName
        if item.isMarkdown {
            do {
                editorContent = try readFile(relativePath: item.relativePath)
                hasUnsavedChanges = false
            } catch {
                logActivity(action: "Read Failed", detail: error.localizedDescription, isError: true)
            }
        } else {
            editorContent = ""
            hasUnsavedChanges = false
        }
    }
    
    public func selectNote(byRelativePath path: String) {
        if let item = noteItem(atRelativePath: path) {
            selectNote(item)
        }
    }

    func noteItem(atRelativePath path: String) -> NoteItem? {
        func findIn(items: [NoteItem]) -> NoteItem? {
            for item in items {
                if item.relativePath == path { return item }
                if let children = item.children, let found = findIn(items: children) {
                    return found
                }
            }
            return nil
        }
        return findIn(items: rootItems)
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
        guard let current = selectedItem, !current.isDirectory, current.isMarkdown else { return }
        if current.isExternal {
            saveExternalFile(current)
            return
        }
        do {
            try writeFile(relativePath: current.relativePath, content: editorContent)
            hasUnsavedChanges = false
        } catch {
            logActivity(action: "Save Failed", detail: error.localizedDescription, isError: true)
        }
    }
    
    // MARK: - Auto-Save

    static let autosaveDelayKey = "autosave_debounce_seconds"

    /// Set while something else is writing into the note (a meeting transcript); auto-save waits
    /// until it's cleared and `scheduleAutosave()` runs again.
    public var isAutosaveSuspended: Bool {
        get { editing.isAutosaveSuspended }
        set { editing.isAutosaveSuspended = newValue }
    }

    /// The Auto-Save Delay from Settings (General › Auto-Save & Synchronization), 1 s by default.
    var autosaveDelay: TimeInterval {
        let seconds = UserDefaults.standard.double(forKey: Self.autosaveDelayKey)
        return seconds > 0 ? seconds : 1.0
    }

    /// Saves the open note once edits have paused for `delay` (the Auto-Save Delay by default).
    /// Each call restarts the wait. Nothing is saved if another note was opened meanwhile (opening
    /// a note already saves the previous one), there are no unsaved changes, or auto-save is suspended.
    public func scheduleAutosave(after delay: TimeInterval? = nil) {
        let session = editing
        session.autosaveTask?.cancel()
        let noteURL = session.selectedItem?.url
        let delay = delay ?? autosaveDelay
        // Saves the window that was typed in, even if another tab is in front by then.
        session.autosaveTask = Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, let session, !Task.isCancelled, !session.isAutosaveSuspended, session.hasUnsavedChanges,
                  noteURL != nil, session.selectedItem?.url == noteURL else { return }
            self.perform(on: session) { self.saveCurrentNote() }
        }
    }

    /// Applies `edit` to the note at `url`: the editor while that note is open, otherwise the file
    /// itself. A meeting transcript keeps finishing after you switch notes, and must stay in its note.
    public func editNote(at url: URL, _ edit: (inout String) -> Void) {
        if let session = session(showing: url) {
            edit(&session.editorContent)
            session.hasUnsavedChanges = true
            return
        }
        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            edit(&content)
            if let relativePath = relativePathInVault(url) {
                try writeFile(relativePath: relativePath, content: content)
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logActivity(action: "Updated File", detail: url.path, isError: false)
            }
        } catch {
            logActivity(action: "Save Failed", detail: "\(url.lastPathComponent): \(error.localizedDescription)", isError: true)
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
    
    /// Runs a file operation started from the sidebar or a menu. A failure is logged and shown
    /// (`errorPresenter`), never silent.
    @discardableResult
    public func reportingErrors(_ title: String, _ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return true
        } catch {
            logActivity(action: title, detail: error.localizedDescription, isError: true)
            errorPresenter?(title, error.localizedDescription)
            return false
        }
    }

    /// Move to Trash from the sidebar, a menu or ⌘⌫. An item that can't go to the Trash (a file
    /// OneDrive has synced) can be deleted immediately instead, after a confirmation, as in Finder.
    public func trash(relativePath: String) {
        do {
            try deleteFile(relativePath: relativePath)
        } catch BrainError.cannotTrash(let path) {
            let name = (path as NSString).lastPathComponent
            let inCloud = vaultURL.path.contains("/Library/CloudStorage/")
            let message = "Do you want to delete it immediately? You can't undo this action."
                + (inCloud ? " Your cloud storage provider may keep a copy in its online recycle bin." : "")
            confirmPresenter?("“\(name)” can't be moved to the Trash.", message, "Delete") { [weak self] confirmed in
                guard confirmed, let self else { return }
                self.reportingErrors("Couldn't Delete") { try self.deleteFile(relativePath: path, permanently: true) }
            }
        } catch {
            reportingErrors("Couldn't Move to Trash") { throw error }
        }
    }

    /// ⌘⌫: deletes to the start of the line while you're editing text (the note editor, or a field
    /// with text in it); otherwise moves the open note to the Trash. An empty field that SwiftUI
    /// focused by itself (the sidebar search, at launch) doesn't count as editing.
    public func commandDelete(firstResponder: NSResponder?) {
        if let textView = firstResponder as? NSTextView, textView is MarkdownNSTextView || !textView.string.isEmpty {
            textView.deleteToBeginningOfLine(nil)
        } else if let item = selectedItem, !item.isExternal {
            trash(relativePath: item.relativePath)
        }
    }

    /// Moves a note, attachment or folder to the Trash, so Finder's Put Back can restore it.
    public func deleteFile(relativePath: String) throws {
        try deleteFile(relativePath: relativePath, permanently: false)
    }

    /// `permanently` deletes without the Trash; only after the user confirmed it (see `trash`).
    func deleteFile(relativePath: String, permanently: Bool) throws {
        let fileURL = try resolveSecurePath(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BrainError.fileNotFound(path: relativePath)
        }
        
        do {
            if permanently {
                try FileManager.default.removeItem(at: fileURL)
            } else {
                do {
                    try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                } catch CocoaError.fileWriteNoPermission {
                    // Files a cloud provider (OneDrive) has synced need Full Disk Access to go to the Trash.
                    throw BrainError.cannotTrash(path: relativePath)
                }
            }
            for session in sessions where session.selectedItem?.relativePath == relativePath {
                session.selectedItem = nil
                session.editorContent = ""
                session.editorTitle = ""
            }
            refreshFiles()
            logActivity(action: permanently ? "Deleted Permanently" : "Moved to Trash", detail: relativePath, isError: false)
        } catch let error as BrainError {
            throw error
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
    
    // MARK: - Attachments & Media
    
    /// Saves an image or attachment file into the configured attachment directory,
    /// generating a unique filename and returning the relative Markdown reference.
    @discardableResult
    public func saveAttachment(
        data: Data,
        suggestedFileName: String? = nil,
        noteURL: URL? = nil
    ) throws -> (savedURL: URL, markdownReference: String) {
        let fm = FileManager.default
        let rawSetting = (UserDefaults.standard.string(forKey: "attachment_folder") ?? "Attachments")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Determine target directory
        let targetDirectory: URL
        let noteDir = noteURL?.deletingLastPathComponent() ?? vaultURL
        
        if rawSetting.isEmpty {
            // Same folder as note
            targetDirectory = noteDir
        } else if rawSetting.hasPrefix("./") {
            // Relative to current note's folder
            let sub = String(rawSetting.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            targetDirectory = noteDir.appendingPathComponent(sub, isDirectory: true)
        } else {
            // In specified folder relative to vault root
            let cleanSub = rawSetting.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            targetDirectory = vaultURL.appendingPathComponent(cleanSub, isDirectory: true)
        }
        
        // Create target directory if needed
        if !fm.fileExists(atPath: targetDirectory.path) {
            try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        }
        
        // 2. Determine file extension and base name
        var ext = (suggestedFileName as NSString?)?.pathExtension.lowercased() ?? ""
        if ext.isEmpty {
            ext = detectImageExtension(data: data) ?? "png"
        }
        
        let rawBaseName = (suggestedFileName as NSString?)?.deletingPathExtension ?? ""
        let baseName: String
        if !rawBaseName.isEmpty && rawBaseName != "image" && rawBaseName.lowercased() != "pasted image" {
            baseName = rawBaseName.replacingOccurrences(of: "/", with: "-")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            baseName = "Pasted-Image-\(formatter.string(from: Date()))"
        }
        
        // 3. Ensure unique filename
        var candidateName = "\(baseName).\(ext)"
        var candidateURL = targetDirectory.appendingPathComponent(candidateName)
        var counter = 1
        while fm.fileExists(atPath: candidateURL.path) {
            candidateName = "\(baseName)-\(counter).\(ext)"
            candidateURL = targetDirectory.appendingPathComponent(candidateName)
            counter += 1
        }
        
        // 4. Write data
        try data.write(to: candidateURL, options: .atomic)
        refreshFiles()
        logActivity(action: "Saved Attachment", detail: candidateName, isError: false)
        
        // 5. Compute markdown reference relative to current note
        let relativeMarkdownPath: String
        let baseDir = (noteURL?.deletingLastPathComponent() ?? vaultURL).standardized.resolvingSymlinksInPath()
        let fileStandard = candidateURL.standardized.resolvingSymlinksInPath()
        
        if fileStandard.deletingLastPathComponent().path == baseDir.path {
            relativeMarkdownPath = candidateName
        } else {
            let baseComponents = baseDir.pathComponents
            let fileComponents = fileStandard.pathComponents
            
            var commonPrefixLen = 0
            while commonPrefixLen < baseComponents.count &&
                  commonPrefixLen < fileComponents.count &&
                  baseComponents[commonPrefixLen] == fileComponents[commonPrefixLen] {
                commonPrefixLen += 1
            }
            
            let upCount = baseComponents.count - commonPrefixLen
            let ups = Array(repeating: "..", count: upCount)
            let downs = fileComponents[commonPrefixLen...]
            let rel = (ups + downs).joined(separator: "/")
            relativeMarkdownPath = rel.isEmpty ? candidateName : rel
        }
        
        let altText = (candidateName as NSString).deletingPathExtension
        let markdownRef = "![\(altText)](\(relativeMarkdownPath))"
        return (savedURL: candidateURL, markdownReference: markdownRef)
    }
    
    private func detectImageExtension(data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        } else if bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return "jpg"
        } else if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "gif"
        } else if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            return "webp"
        }
        return nil
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
            if !oldExt.isEmpty && !targetName.lowercased().hasSuffix(".\(oldExt.lowercased())") {
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
        
        // Flush unsaved changes in every window, so none are lost when its note moves
        saveAllNotes()
        let shown = notesShown()
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            let newRelPath = relativePath(of: newURL, relativeTo: vaultURL)
            refreshFiles()
            
            // A renamed note opens in the front tab, unless a tab already shows it.
            if !isDir.boolValue, !shown.contains(where: { $0.1 == oldRelativePath }) {
                selectNote(byRelativePath: newRelPath)
            }
            follow(shown, from: oldRelativePath, to: newRelPath)
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
        
        saveAllNotes()
        
        do {
            let isSourceDirectory = (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let shown = notesShown()
            
            try fm.moveItem(at: sourceURL, to: targetURL)
            let newRelPath = relativePath(of: targetURL, relativeTo: vaultURL)
            refreshFiles()
            
            if !isSourceDirectory, !shown.contains(where: { $0.1 == sourceRelativePath }) {
                selectNote(byRelativePath: newRelPath)
            }
            follow(shown, from: sourceRelativePath, to: newRelPath)
            
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
            } else if !file.lastPathComponent.hasPrefix(".") && !file.pathExtension.isEmpty && !isTagOnly {
                let fileName = file.lastPathComponent
                if fileName.lowercased().contains(query) {
                    let relPath = relativePath(of: file, relativeTo: base)
                    results.append(NoteSearchResult(
                        relativePath: relPath,
                        title: fileName,
                        snippet: "Attachment (\(file.pathExtension.uppercased()))"
                    ))
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
            } else if !item.isDirectory && item.isMarkdown {
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
        // Close the old vault's tabs without forgetting them, then reopen the new vault's.
        let defaults = tabsDefaults
        tabsDefaults = nil
        closeOtherSessions()
        selectedItem = nil
        editorContent = ""
        editorTitle = ""
        vaultURL = newURL.standardized.resolvingSymlinksInPath()
        UserDefaults.standard.set(vaultURL.path, forKey: userDefaultsVaultKey)
        refreshFiles()
        startFileWatcher()
        tabsDefaults = defaults
        restoreTabs()
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
