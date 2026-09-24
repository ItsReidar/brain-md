//
//  brain_mdTests.swift
//  brain-mdTests
//

import Testing
import Foundation
import SwiftUI
@testable import brain_md

@Suite(.serialized)
@MainActor
struct brain_mdTests {

    @Test func testVaultCRUDAndSearch() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Create note
        let noteName = "TestNote.md"
        let initialContent = "# Hello Brain\nThis is a unit test note."
        try vault.createFile(relativePath: noteName, content: initialContent)
        
        // 2. Read note
        let readContent = try vault.readFile(relativePath: noteName)
        #expect(readContent == initialContent)
        
        // 3. Append note
        try vault.appendFile(relativePath: noteName, contentToAppend: "\nAppended line.")
        let updatedContent = try vault.readFile(relativePath: noteName)
        #expect(updatedContent.contains("Appended line."))
        
        // 4. Search notes
        let results = vault.searchNotes(query: "Hello Brain")
        #expect(!results.isEmpty)
        #expect(results.contains(where: { $0.relativePath == "TestNote.md" }))
        
        // 5. Delete note
        try vault.deleteFile(relativePath: noteName)
        #expect(throws: BrainError.self) {
            _ = try vault.readFile(relativePath: noteName)
        }
    }
    
    @Test func testPathTraversalProtection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_security_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        #expect(throws: BrainError.self) {
            _ = try vault.readFile(relativePath: "../../../etc/passwd")
        }
        
        #expect(throws: BrainError.self) {
            try vault.createFile(relativePath: "../../../tmp/hacked.md", content: "evil")
        }
    }

    @Test func testAnyCodableSubscriptsAndLiterals() {
        let dictVal: AnyCodableValue = [            "name": "brain-md",
            "version": 1,
            "enabled": true,
            "tools": ["list_notes", "read_note"]        ]
        #expect(dictVal["name"]?.stringValue == "brain-md")
        #expect(dictVal["version"]?.intValue == 1)
        #expect(dictVal["enabled"]?.boolValue == true)
        #expect(dictVal["tools"]?.arrayValue?.count == 2)
    }

    @Test func testMCPServerProtocol() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_mcp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        let server = MCPServer(vault: vault)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // 1. Initialize
        let initReq = JSONRPCRequest(id: .int(1), method: "initialize")
        let initData = try encoder.encode(initReq)
        let initRespData = await server.handleRequest(data: initData)
        let initResp = try decoder.decode(JSONRPCResponse.self, from: initRespData!)
        #expect(initResp.result?["serverInfo"]?["name"]?.stringValue == "brain-md")
        
        // 2. Tools List
        let toolsReq = JSONRPCRequest(id: .int(2), method: "tools/list")
        let toolsData = try encoder.encode(toolsReq)
        let toolsRespData = await server.handleRequest(data: toolsData)
        let toolsResp = try decoder.decode(JSONRPCResponse.self, from: toolsRespData!)
        let tools = toolsResp.result?["tools"]?.arrayValue ?? []
        #expect(!tools.isEmpty)
        
        // 3. Create Note via MCP Tool Call
        let createParams: [String: AnyCodableValue] = [            "name": "create_note",
            "arguments": [                "path": "AgentNote.md",
                "content": "# Agent Note\nCreated via MCP tool call."
            ]        ]
        let callReq = JSONRPCRequest(id: .int(3), method: "tools/call", params: createParams)
        let callData = try encoder.encode(callReq)
        let callRespData = await server.handleRequest(data: callData)
        let callResp = try decoder.decode(JSONRPCResponse.self, from: callRespData!)
        #expect(callResp.result?["isError"]?.boolValue == false)
        
        // 4. Read Note via MCP Tool Call
        let readParams: [String: AnyCodableValue] = [            "name": "read_note",
            "arguments": ["path": "AgentNote.md"]        ]
        let readReq = JSONRPCRequest(id: .int(4), method: "tools/call", params: readParams)
        let readData = try encoder.encode(readReq)
        let readRespData = await server.handleRequest(data: readData)
        let readResp = try decoder.decode(JSONRPCResponse.self, from: readRespData!)
        let contentArr = readResp.result?["content"]?.arrayValue
        let text = contentArr?.first?["text"]?.stringValue
        #expect(text?.contains("Created via MCP tool call.") == true)
        
        // 5. Update Note (append) via MCP Tool Call
        let updateParams: [String: AnyCodableValue] = [            "name": "update_note",
            "arguments": [                "path": "AgentNote.md",
                "content": "\nAdditional insight from agent.",
                "mode": "append"
            ]        ]
        let toolUpdateReq = JSONRPCRequest(id: .int(5), method: "tools/call", params: updateParams)
        let toolUpdateData = try encoder.encode(toolUpdateReq)
        let updateRespData = await server.handleRequest(data: toolUpdateData)
        let updateResp = try decoder.decode(JSONRPCResponse.self, from: updateRespData!)
        #expect(updateResp.result?["isError"]?.boolValue == false)
        
        // 6. Search Notes via MCP Tool Call
        let searchParams: [String: AnyCodableValue] = [            "name": "search_notes",
            "arguments": ["query": "Additional insight"]        ]
        let searchReq = JSONRPCRequest(id: .int(6), method: "tools/call", params: searchParams)
        let searchData = try encoder.encode(searchReq)
        let searchRespData = await server.handleRequest(data: searchData)
        let searchResp = try decoder.decode(JSONRPCResponse.self, from: searchRespData!)
        #expect(searchResp.result?["isError"]?.boolValue == false)
        
        // 7. Get Vault Stats via MCP Tool Call
        let statsParams: [String: AnyCodableValue] = [            "name": "get_vault_stats",
            "arguments": [:]        ]
        let statsReq = JSONRPCRequest(id: .int(7), method: "tools/call", params: statsParams)
        let statsData = try encoder.encode(statsReq)
        let statsRespData = await server.handleRequest(data: statsData)
        let statsResp = try decoder.decode(JSONRPCResponse.self, from: statsRespData!)
        #expect(statsResp.result?["isError"]?.boolValue == false)
        
        // 8. Resources List & Read
        let resListReq = JSONRPCRequest(id: .int(8), method: "resources/list")
        let resListData = try encoder.encode(resListReq)
        let resListRespData = await server.handleRequest(data: resListData)
        let resListResp = try decoder.decode(JSONRPCResponse.self, from: resListRespData!)
        let resources = resListResp.result?["resources"]?.arrayValue ?? []
        #expect(!resources.isEmpty)
        #expect(resources.contains(where: { $0["uri"]?.stringValue == "note://AgentNote.md" }))
    }

    @Test func testMCPSingleLineJSONResponse() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_singleline_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        let server = MCPServer(vault: vault)
        
        let reqJSON = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n"
        let respData = await server.handleRequest(data: reqJSON.data(using: .utf8)!)
        #expect(respData != nil)
        let respStr = String(data: respData!, encoding: .utf8)!
        #expect(!respStr.contains("\n") || respStr.hasSuffix("\n"))
    }

    @Test func testSyntaxHighlighter() {
        let swiftCode = """
        import Foundation
        // Test comment
        func test() -> String {
            return "Hello, World!"
        }
        """
        let highlightedLight = SyntaxHighlighter.highlight(code: swiftCode, language: .swift, isDark: false)
        let highlightedDark = SyntaxHighlighter.highlight(code: swiftCode, language: .swift, isDark: true)
        
        let textLight = String(highlightedLight.characters)
        let textDark = String(highlightedDark.characters)
        #expect(textLight.contains("Hello, World!"))
        #expect(textDark.contains("Hello, World!"))
        #expect(textDark.contains("func test()"))
        
        // Verify themes exist and have valid definitions
        #expect(SyntaxTheme.githubDark.name == "GitHub Dark")
        #expect(SyntaxTheme.githubLight.name == "GitHub Light")
        #expect(SyntaxTheme.dracula.name == "Dracula")
        #expect(SyntaxTheme.monokai.name == "Monokai")
    }
    
    @Test func testSyntaxHighlighterHTML() {
        let swiftCode = """
        // Example Swift
        import Foundation
        struct User {
            let id: Int = 101
            var name: String = "Alice"
        }
        func calculate(total: Double) -> Double {
            return total * 1.21
        }
        """
        let htmlSwift = SyntaxHighlighter.highlightToHTML(code: swiftCode, language: .swift)
        #expect(htmlSwift.contains("<span class=\"tok-comment\">// Example Swift</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-kw\">import</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-kw\">struct</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-type\">User</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-num\">101</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-str\">&quot;Alice&quot;</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-fn\">calculate</span>"))
        #expect(htmlSwift.contains("<span class=\"tok-kw\">return</span>"))
        
        let jsonCode = """
        {
            "status": "active",
            "count": 42
        }
        """
        let htmlJSON = SyntaxHighlighter.highlightToHTML(code: jsonCode, language: .json)
        #expect(htmlJSON.contains("<span class=\"tok-key\">&quot;status&quot;</span>"))
        #expect(htmlJSON.contains("<span class=\"tok-num\">42</span>"))
        
        let plainCode = "Hello <World> & Everyone"
        let htmlPlain = SyntaxHighlighter.highlightToHTML(code: plainCode, language: .plain)
        #expect(htmlPlain == "Hello &lt;World&gt; &amp; Everyone")
    }
    
    @Test func testGFMBlockParsing() {
        let markdown = """
        > [!NOTE]
        > Useful information that users or AI agents should know.
        
        | Feature | Status |
        | :--- | :---: |
        | MCP Stdio | Active |
        
        - [x] Implemented GitHub Alerts
        - [ ] Unchecked item
        """
        
        let doc = MarkdownPreviewView.parseDocument(markdown)
        
        // Verify Alert Block was recognized
        let hasAlert = doc.blocks.contains { block in
            if case .alert(let type, let content) = block {
                return type == .note && content.contains("Useful information")
            }
            return false
        }
        #expect(hasAlert)
        
        // Verify Table Block was parsed
        let hasTable = doc.blocks.contains { block in
            if case .table(let headers, _, let rows) = block {
                return headers.first == "Feature" && rows.first?.first == "MCP Stdio"
            }
            return false
        }
        #expect(hasTable)
        
        // Verify Task List Items were recognized
        let hasCheckedTask = doc.blocks.contains { block in
            if case .taskItem(let isChecked, let text) = block {
                return isChecked && text.contains("Implemented GitHub Alerts")
            }
            return false
        }
        #expect(hasCheckedTask)
        
        let hasUncheckedTask = doc.blocks.contains { block in
            if case .taskItem(let isChecked, let text) = block {
                return !isChecked && text.contains("Unchecked item")
            }
            return false
        }
        #expect(hasUncheckedTask)
    }
    
    @Test func testTableParsingAndAlignment() {
        let markdown = """
        | Attribute | Details |
        | :--- | :--- |
        | Headquarters | Mechelen, Belgium |
        | Parent Company | Liberty Global |
        | Primary Market | Flanders & Brussels |
        | Core Brands | Telenet, BASE, Telenet Business, Play Media |
        """
        
        let doc = MarkdownPreviewView.parseDocument(markdown)
        #expect(doc.blocks.count == 1)
        
        guard case .table(let headers, let alignments, let rows) = doc.blocks.first else {
            Issue.record("Expected table block")
            return
        }
        
        #expect(headers == ["Attribute", "Details"])
        #expect(alignments == [.leading, .leading])
        #expect(rows.count == 4)
        #expect(rows[0] == ["Headquarters", "Mechelen, Belgium"])
        #expect(rows[1] == ["Parent Company", "Liberty Global"])
        #expect(rows[2] == ["Primary Market", "Flanders & Brussels"])
        #expect(rows[3] == ["Core Brands", "Telenet, BASE, Telenet Business, Play Media"])
    }
    
    @Test func testMarkdownPreviewViewRendering() {
        let sampleMarkdown = """
        ---
        title: Sample Preview
        tags: [swift, test]
        ---
        # Header 1
        This is a test paragraph with **bold** and *italic* text.
        
        | Col A | Col B |
        | :--- | :---: |
        | 1 | 2 |
        
        ```swift
        let test = "code"
        ```
        """
        let preview = MarkdownPreviewView(markdown: sampleMarkdown)
        #expect(preview.markdown.contains("Sample Preview"))
        
        let doc = MarkdownPreviewView.parseDocument(sampleMarkdown)
        #expect(!doc.blocks.isEmpty)
    }
    
    @Test func testMarkdownHTMLRenderer() {
        let sampleMarkdown = """
        ---
        title: HTML Render Test
        tags: [swift, html]
        ---
        # Document Title
        Here is a paragraph with **bold text** and `inline code`.
        
        | Feature | Status |
        | :--- | :--- |
        | Fast | Yes |
        
        ```swift
        let x = 42
        ```
        
        ```mermaid
        graph LR
            A --> B
        ```
        """
        let theme = TerminalThemes.dark[0]
        let html = MarkdownHTMLRenderer.renderHTML(markdown: sampleMarkdown, theme: theme, contentWidth: 850)
        
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("<h1") && html.contains("Document Title</h1>"))
        #expect(html.contains("<strong>bold text</strong>"))
        #expect(html.contains("<code>inline code</code>"))
        #expect(html.contains("<table") && html.contains("Feature</th>"))
        #expect(html.contains("code-block-container"))
        #expect(html.contains("window-dots"))
        #expect(html.contains("<span class=\"tok-kw\">let</span>"))
        #expect(html.contains("<span class=\"tok-num\">42</span>"))
        #expect(html.contains("mermaid"))
        #expect(html.contains(theme.backgroundHex))
    }

    @Test func testMermaidDiagramSupport() {
        let markdown = """
        # Project Architecture
        
        Here is our workflow:
        
        ```mermaid
        graph TD
            A[Client] -->|Request| B(MCP Server)
            B -->|File CRUD| C[(Notes Vault)]
        ```
        
        And standard code block:
        ```swift
        let x = 42
        ```
        """
        
        let doc = MarkdownPreviewView.parseDocument(markdown)
        
        // Verify Mermaid block was parsed specifically as mermaidDiagram
        let mermaidBlocks = doc.blocks.filter { block in
            if case .mermaidDiagram = block { return true }
            return false
        }
        #expect(mermaidBlocks.count == 1)
        
        if case .mermaidDiagram(let code) = mermaidBlocks.first {
            #expect(code.contains("graph TD"))
            #expect(code.contains("A[Client] -->|Request| B(MCP Server)"))
            #expect(code.contains("Notes Vault"))
        }
        
        // Verify standard code block is still parsed as codeBlock
        let codeBlocks = doc.blocks.filter { block in
            if case .codeBlock = block { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        if case .codeBlock(let lang, let code) = codeBlocks.first {
            #expect(lang == "swift")
            #expect(code.contains("let x = 42"))
        }
        
        // Verify Mermaid script provider
        let script = MermaidScriptProvider.getScript()
        #expect(!script.isEmpty)
        #expect(script.contains("mermaid"))
        
        // Verify HTML template generates valid payload
        let html = MermaidHTMLTemplate.generate()
        #expect(html.contains("<script>"))
        #expect(html.contains("window.renderMermaid"))
        #expect(html.contains("webkit.messageHandlers.mermaidHandler.postMessage"))
    }

    @Test func testNewNoteAutoSwitchingAndUniqueNaming() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_autoswitch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Initial unique path is Untitled.md
        let path1 = vault.generateUniqueNotePath(baseName: "Untitled")
        #expect(path1 == "Untitled.md")
        
        // 2. Create note 1 -> selectedItem should automatically switch to Untitled.md
        try vault.createFile(relativePath: path1, content: "# First Note\n")
        #expect(vault.selectedItem?.relativePath == "Untitled.md")
        #expect(vault.editorContent.contains("# First Note"))
        
        // 3. Modifying editorContent
        vault.editorContent = "# First Note with Edits\n"
        vault.hasUnsavedChanges = true
        
        // 4. Next unique path should be Untitled 1.md
        let path2 = vault.generateUniqueNotePath(baseName: "Untitled")
        #expect(path2 == "Untitled 1.md")
        
        // 5. Creating note 2 -> should auto-save previous note edits and switch to Untitled 1.md
        try vault.createFile(relativePath: path2, content: "# Second Note\n")
        #expect(vault.selectedItem?.relativePath == "Untitled 1.md")
        #expect(vault.editorContent.contains("# Second Note"))
        
        // 6. Verify previous note was automatically saved
        let readBackFirst = try vault.readFile(relativePath: "Untitled.md")
        #expect(readBackFirst == "# First Note with Edits\n")
        
        // 7. Switching back to first note via selectNote(byRelativePath:)
        vault.selectNote(byRelativePath: "Untitled.md")
        #expect(vault.selectedItem?.relativePath == "Untitled.md")
        #expect(vault.editorContent == "# First Note with Edits\n")
    }

    @Test func testDragAndDropNoteMoving() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_dnd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Setup folders and notes
        try vault.createFolder(relativePath: "Projects")
        try vault.createFolder(relativePath: "Archive")
        try vault.createFile(relativePath: "Task.md", content: "# Task\nDraft task.")
        
        #expect(vault.selectedItem?.relativePath == "Task.md")
        
        // 2. Move note from root INTO folder "Projects"
        try vault.moveItem(sourceRelativePath: "Task.md", toDirectoryRelativePath: "Projects")
        #expect(vault.selectedItem?.relativePath == "Projects/Task.md")
        let taskInProjects = try vault.readFile(relativePath: "Projects/Task.md")
        #expect(taskInProjects.contains("Draft task."))
        
        // Verify source file no longer exists at root
        #expect(throws: BrainError.self) {
            _ = try vault.readFile(relativePath: "Task.md")
        }
        
        // 3. Move note OUT of folder "Projects" back to root ""
        try vault.moveItem(sourceRelativePath: "Projects/Task.md", toDirectoryRelativePath: "")
        #expect(vault.selectedItem?.relativePath == "Task.md")
        let taskBackAtRoot = try vault.readFile(relativePath: "Task.md")
        #expect(taskBackAtRoot.contains("Draft task."))
        
        // 4. Move using intoContainerOf another note
        try vault.createFile(relativePath: "Archive/History.md", content: "# Old History")
        let historyItem = NoteItem(
            name: "History.md",
            relativePath: "Archive/History.md",
            url: tempDir.appendingPathComponent("Archive/History.md"),
            isDirectory: false
        )
        try vault.moveItem(sourceRelativePath: "Task.md", intoContainerOf: historyItem)
        #expect(vault.selectedItem?.relativePath == "Archive/Task.md")
        let taskInArchive = try vault.readFile(relativePath: "Archive/Task.md")
        #expect(taskInArchive.contains("Draft task."))
        
        // 5. Collision handling: create another Task.md in root, and move Archive/Task.md to root
        try vault.createFile(relativePath: "Task.md", content: "# New Task at Root")
        try vault.moveItem(sourceRelativePath: "Archive/Task.md", toDirectoryRelativePath: "")
        
        // It should have renamed to Task 1.md
        let renamedContent = try vault.readFile(relativePath: "Task 1.md")
        #expect(renamedContent.contains("Draft task."))
        
        // Original root file is untouched
        let rootContent = try vault.readFile(relativePath: "Task.md")
        #expect(rootContent.contains("New Task at Root"))
        
        // 6. Prevent self-nesting directory move
        #expect(throws: BrainError.self) {
            try vault.moveItem(sourceRelativePath: "Projects", toDirectoryRelativePath: "Projects")
        }
        
        // 7. Verify MCP move_note tool
        let server = MCPServer(vault: vault)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let mcpMoveParams: [String: AnyCodableValue] = [            "name": "move_note",
            "arguments": [                "sourcePath": "Task 1.md",
                "targetFolder": "Projects"
            ]        ]
        let mcpReq = JSONRPCRequest(id: .int(99), method: "tools/call", params: mcpMoveParams)
        let reqData = try encoder.encode(mcpReq)
        let respData = await server.handleRequest(data: reqData)
        let resp = try decoder.decode(JSONRPCResponse.self, from: respData!)
        #expect(resp.result?["isError"]?.boolValue == false)
        
        let mcpMovedContent = try vault.readFile(relativePath: "Projects/Task 1.md")
        #expect(mcpMovedContent.contains("Draft task."))
    }

    @Test func testFolderMoveAndRenamePreservesSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_folder_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Create a note and verify rename preserves selection
        try vault.createFile(relativePath: "Draft.md", content: "# Draft Content")
        #expect(vault.selectedItem?.relativePath == "Draft.md")
        
        try vault.renameItem(oldRelativePath: "Draft.md", newName: "Final.md")
        #expect(vault.selectedItem?.relativePath == "Final.md")
        #expect(vault.editorContent == "# Draft Content")
        
        // 2. Create subfolder and move note into it
        try vault.createFolder(relativePath: "Work")
        try vault.moveItem(sourceRelativePath: "Final.md", toDirectoryRelativePath: "Work")
        #expect(vault.selectedItem?.relativePath == "Work/Final.md")
        #expect(vault.editorContent == "# Draft Content")
        
        // 3. Move enclosing folder and verify selected note path updates
        try vault.createFolder(relativePath: "Archive")
        try vault.moveItem(sourceRelativePath: "Work", toDirectoryRelativePath: "Archive")
        #expect(vault.selectedItem?.relativePath == "Archive/Work/Final.md")
        #expect(vault.editorContent == "# Draft Content")
    }

    @Test func testNoteRenameWithoutExtensionAndSafety() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_rename_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Create a note and rename without typing ".md"
        try vault.createFile(relativePath: "Ideas.md", content: "# Initial Ideas")
        #expect(vault.selectedItem?.relativePath == "Ideas.md")
        
        // Renaming with "Project Plans" (no extension)
        try vault.renameItem(oldRelativePath: "Ideas.md", newName: "Project Plans")
        
        // Must preserve .md extension on disk and in vault indexing
        #expect(vault.selectedItem?.relativePath == "Project Plans.md")
        #expect(vault.editorContent == "# Initial Ideas")
        #expect(vault.rootItems.contains { $0.relativePath == "Project Plans.md" })
        #expect(!vault.rootItems.contains { $0.relativePath == "Ideas.md" })
        
        let onDiskURL = tempDir.appendingPathComponent("Project Plans.md")
        #expect(FileManager.default.fileExists(atPath: onDiskURL.path))
        
        // 2. Rename note while having unsaved editor changes
        vault.editorContent = "# Updated Ideas"
        vault.hasUnsavedChanges = true
        
        try vault.renameItem(oldRelativePath: "Project Plans.md", newName: "Final Plans")
        #expect(vault.selectedItem?.relativePath == "Final Plans.md")
        #expect(vault.editorContent == "# Updated Ideas")
        #expect(vault.hasUnsavedChanges == false)
        
        let finalURL = tempDir.appendingPathComponent("Final Plans.md")
        let savedDiskContent = try String(contentsOf: finalURL, encoding: .utf8)
        #expect(savedDiskContent == "# Updated Ideas")
        
        // 3. Collision protection: cannot rename to an already existing note name
        try vault.createFile(relativePath: "Existing.md", content: "# Existing")
        
        #expect(throws: BrainError.self) {
            try vault.renameItem(oldRelativePath: "Final Plans.md", newName: "Existing")
        }
        
        // 4. Path traversal / slashes rejection
        #expect(throws: BrainError.self) {
            try vault.renameItem(oldRelativePath: "Final Plans.md", newName: "../Evil")
        }
    }

    @Test func testSettingsDefaultsAndAppStorage() {
        // 1. Verify all 7 tabs in the settings registry
        let tabs = SettingsTab.allCases
        #expect(tabs.count == 7)
        #expect(tabs.contains(.general))
        #expect(tabs.contains(.appearance))
        #expect(tabs.contains(.editor))
        #expect(tabs.contains(.mcpServer))
        #expect(tabs.contains(.vault))
        #expect(tabs.contains(.advanced))
        #expect(tabs.contains(.about))
        
        // 2. Verify tabs have non-empty titles, icons, and colors
        for tab in tabs {
            #expect(!tab.rawValue.isEmpty)
            #expect(!tab.iconName.isEmpty)
            #expect(tab.id == tab.rawValue)
        }
        
        // 3. Verify default settings preferences can be read from UserDefaults
        let defaults = UserDefaults.standard
        let defaultPort = defaults.integer(forKey: "mcp_preferred_port")
        // If not explicitly set, integer is 0 or user default
        #expect(defaultPort >= 0)
        
        defaults.set(800.0, forKey: "preview_content_width")
        #expect(defaults.double(forKey: "preview_content_width") == 800.0)
    }

    @Test func testNoteTemplateEngineTitlePresets() {
        let fixedDate = Date(timeIntervalSince1970: 1773840000) // 2026-03-18
        
        // 1. Untitled
        #expect(NoteTemplateEngine.resolveTitle(preset: "untitled", date: fixedDate) == "Untitled")
        
        // 2. Date
        let dateTitle = NoteTemplateEngine.resolveTitle(preset: "date", date: fixedDate)
        #expect(dateTitle == "2026-03-18")
        
        // 3. Journal
        let journalTitle = NoteTemplateEngine.resolveTitle(preset: "journal", date: fixedDate)
        #expect(journalTitle == "Journal 2026-03-18")
        
        // 4. Custom with tokens
        let customFormat = "Meeting-{date}-{year}_{month}_{day}"
        let customTitle = NoteTemplateEngine.resolveTitle(preset: "custom", customFormat: customFormat, date: fixedDate)
        #expect(customTitle == "Meeting-2026-03-18-2026_03_18")
        
        // 5. Sanitization of illegal characters (/ and :)
        let sanitized = NoteTemplateEngine.resolveTitle(preset: "custom", customFormat: "Sprint/Review:Demo", date: fixedDate)
        #expect(!sanitized.contains("/"))
        #expect(!sanitized.contains(":"))
        #expect(sanitized == "Sprint-Review-Demo")
        
        // 6. Fallback on empty custom string
        let emptyCustom = NoteTemplateEngine.resolveTitle(preset: "custom", customFormat: "   ", date: fixedDate)
        #expect(emptyCustom == "Untitled")
    }

    @Test func testNoteTemplateEngineContentPresets() {
        let fixedDate = Date(timeIntervalSince1970: 1773840000) // 2026-03-18
        
        // 1. Heading only
        let headingContent = NoteTemplateEngine.resolveContent(preset: "heading", title: "My First Note", date: fixedDate)
        #expect(headingContent == "# My First Note\n\n")
        
        // 2. Date & Heading
        let dateHeadingContent = NoteTemplateEngine.resolveContent(preset: "dateHeading", title: "Project Spec", date: fixedDate)
        #expect(dateHeadingContent.contains("# Project Spec"))
        #expect(dateHeadingContent.contains("*Created: 2026-03-18*"))
        
        // 3. Blank
        let blankContent = NoteTemplateEngine.resolveContent(preset: "blank", title: "Empty", date: fixedDate)
        #expect(blankContent == "")
        
        // 4. Meeting Notes preset
        let meetingContent = NoteTemplateEngine.resolveContent(preset: "meeting", title: "Standup", date: fixedDate)
        #expect(meetingContent.contains("# Standup"))
        #expect(meetingContent.contains("**Date:** 2026-03-18"))
        #expect(meetingContent.contains("## Agenda"))
        #expect(meetingContent.contains("## Action Items"))
        
        // 5. Custom template with double and single curly braces
        let customTemplate = """
        ---
        title: {{title}}
        created: {date}
        ---
        # {title}
        
        Welcome to {{title}}!
        """
        let customResult = NoteTemplateEngine.resolveContent(
            preset: "custom",
            customTemplate: customTemplate,
            title: "Roadmap",
            date: fixedDate
        )
        #expect(customResult.contains("title: Roadmap"))
        #expect(customResult.contains("created: 2026-03-18"))
        #expect(customResult.contains("# Roadmap"))
        #expect(customResult.contains("Welcome to Roadmap!"))
    }

    @Test func testVaultCreateNoteFromTemplate() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Create first note from template
        let firstNotePath = try vault.createNoteFromTemplate()
        #expect(firstNotePath.hasSuffix(".md"))
        let firstContent = try vault.readFile(relativePath: firstNotePath)
        #expect(!firstContent.isEmpty)
        
        // 2. Create second note from template (should resolve unique filename)
        let secondNotePath = try vault.createNoteFromTemplate()
        #expect(secondNotePath != firstNotePath)
        #expect(secondNotePath.hasSuffix(".md"))
        let secondContent = try vault.readFile(relativePath: secondNotePath)
        #expect(!secondContent.isEmpty)
    }

    @Test func testHomeScreenNewNotePromptFlow() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Resolve default candidate title (as done on button tap)
        let defaultTitle = NoteTemplateEngine.resolveTitle(from: .standard)
        let uniquePath = vault.generateUniqueNotePath(baseName: defaultTitle)
        #expect(uniquePath.hasSuffix(".md"))
        
        // 2. Simulate user providing custom note name
        let userInput = "My Custom Architecture Note"
        var finalName = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalName.hasSuffix(".md") && !finalName.contains(".") {
            finalName += ".md"
        }
        #expect(finalName == "My Custom Architecture Note.md")
        
        let title = (finalName as NSString).deletingPathExtension
        let content = NoteTemplateEngine.resolveContent(for: title, from: .standard)
        try vault.createFile(relativePath: finalName, content: content)
        
        // 3. Verify file exists, contains template, and is selected in vault
        let savedContent = try vault.readFile(relativePath: finalName)
        #expect(savedContent == content)
        #expect(vault.selectedItem?.relativePath == finalName)
    }

    @Test func testPromptNewNoteAndCreateNoteNamed() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_prompt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // 1. Initial prompt state should be false
        #expect(vault.showingNewNotePrompt == false)
        #expect(vault.newNotePromptDefaultName.isEmpty)
        
        // 2. Triggering promptNewNote() (simulating ⌘N shortcut)
        vault.promptNewNote()
        #expect(vault.showingNewNotePrompt == true)
        #expect(!vault.newNotePromptDefaultName.isEmpty)
        #expect(vault.newNotePromptDefaultName.hasSuffix(".md"))
        
        // 3. User submits note name using createNote(named:)
        let createdPath = try vault.createNote(named: "Sprint Architecture")
        #expect(createdPath == "Sprint Architecture.md")
        #expect(vault.selectedItem?.relativePath == "Sprint Architecture.md")
        
        let content = try vault.readFile(relativePath: createdPath)
        let expectedContent = NoteTemplateEngine.resolveContent(for: "Sprint Architecture", from: .standard)
        #expect(content == expectedContent)
        
        // 4. Invalid / empty note name throws error
        #expect(throws: BrainError.self) {
            try vault.createNote(named: "   ")
        }
    }

    @Test func testFrontmatterParserStandard() {
        let markdown = """
        ---
        title: System Architecture
        date: 2026-09-18
        author: Team
        tags: [swift, macos, mcp]
        status: Published
        ---
        # System Architecture
        
        This document details the architecture.
        """
        
        let (fm, body) = FrontmatterParser.parse(markdown)
        #expect(fm != nil)
        #expect(fm?.title == "System Architecture")
        #expect(fm?.date == "2026-09-18")
        #expect(fm?.author == "Team")
        #expect(fm?.status == "Published")
        #expect(fm?.tags == ["swift", "macos", "mcp"])
        #expect(body.hasPrefix("# System Architecture"))
        #expect(!body.contains("---"))
    }

    @Test func testFrontmatterParserVariations() {
        // 1. Multiline list for tags
        let multiline = """
        ---
        title: Multi Tags Note
        tags:
          - mobile
          - desktop
          - "cross-platform"
        pinned: true
        ---
        Note content here.
        """
        let (fmMlt, bodyMlt) = FrontmatterParser.parse(multiline)
        #expect(fmMlt?.tags == ["mobile", "desktop", "cross-platform"])
        #expect(bodyMlt.contains("Note content here."))
        
        // 2. Comma separated tags with '#' stripped
        let comma = """
        ---
        tags: #frontend, #react, backend
        ---
        Body text.
        """
        let (fmComma, _) = FrontmatterParser.parse(comma)
        #expect(fmComma?.tags == ["frontend", "react", "backend"])
        
        // 3. Single tag with 'tag:' key
        let single = """
        ---
        tag: "solo"
        ---
        Solo body.
        """
        let (fmSingle, _) = FrontmatterParser.parse(single)
        #expect(fmSingle?.tags == ["solo"])
    }

    @Test func testFrontmatterQuotesStripping() {
        // 1. Double quotes around title and tags
        let doubleQuoted = """
        ---
        title: "Clean Double Title"
        tags: ["swift", "macos"]
        author: "Dev Team"
        ---
        Body content.
        """
        let (fm1, _) = FrontmatterParser.parse(doubleQuoted)
        #expect(fm1?.title == "Clean Double Title")
        #expect(fm1?.author == "Dev Team")
        #expect(fm1?.tags == ["swift", "macos"])
        
        // 2. Single quotes around title
        let singleQuoted = """
        ---
        title: 'Single Quoted Title'
        category: 'Development'
        ---
        Content.
        """
        let (fm2, _) = FrontmatterParser.parse(singleQuoted)
        #expect(fm2?.title == "Single Quoted Title")
        #expect(fm2?.properties.first(where: { $0.key == "category" })?.value == "Development")
        
        // 3. Smart/curly quotes (macOS typography)
        let smartQuoted = """
        ---
        title: “Smart Quoted Title”
        status: ‘Draft’
        ---
        Content.
        """
        let (fm3, _) = FrontmatterParser.parse(smartQuoted)
        #expect(fm3?.title == "Smart Quoted Title")
        #expect(fm3?.status == "Draft")
        
        // 4. Repeated/doubled quotes and trailing comments
        let repeatedAndComment = """
        ---
        title: ""Doubled Quotes Title"" # Inline comment
        notes: ''Empty Quote Test''
        ---
        Content.
        """
        let (fm4, _) = FrontmatterParser.parse(repeatedAndComment)
        #expect(fm4?.title == "Doubled Quotes Title")
        #expect(fm4?.properties.first(where: { $0.key == "notes" })?.value == "Empty Quote Test")
        
        // 5. Empty quotes should resolve to empty string
        let emptyQuotes = """
        ---
        title: ""
        author: ''
        description: “”
        ---
        Content.
        """
        let (fm5, _) = FrontmatterParser.parse(emptyQuotes)
        #expect(fm5?.title == "")
        #expect(fm5?.author == "")
        #expect(fm5?.properties.first(where: { $0.key == "description" })?.value == "")
        
        // 6. Quoted tags and trailing commas in array format
        let quotedTagsTrailingComma = """
        ---
        title: “telenet-strategy”
        Date: 2026-09-23 | 16:24
        Description: “Strategy note”
        tags: ["telecom", ]
        ---
        Some strategy
        """
        let (fm6, _) = FrontmatterParser.parse(quotedTagsTrailingComma)
        #expect(fm6?.title == "telenet-strategy")
        #expect(fm6?.properties.first(where: { $0.key.lowercased() == "description" })?.value == "Strategy note")
        #expect(fm6?.tags == ["telecom"])
        #expect(fm6?.properties.first(where: { $0.key == "tags" })?.tags == ["telecom"])
        #expect(fm6?.properties.first(where: { $0.key == "tags" })?.value == "telecom")
        
        // 7. Unquoted tags with trailing comma: [telecom, ]
        let unquotedTagsTrailingComma = """
        ---
        tags: [telecom, ]
        ---
        Content.
        """
        let (fm7, _) = FrontmatterParser.parse(unquotedTagsTrailingComma)
        #expect(fm7?.tags == ["telecom"])
        #expect(fm7?.properties.first(where: { $0.key == "tags" })?.tags == ["telecom"])
        #expect(fm7?.properties.first(where: { $0.key == "tags" })?.value == "telecom")
        
        // 8. Smart/curly quoted tags in array with trailing comma: [“telecom”, “belgium”, ]
        let smartQuotedTags = """
        ---
        tags: [“telecom”, ‘belgium’, ]
        ---
        Content.
        """
        let (fm8, _) = FrontmatterParser.parse(smartQuotedTags)
        #expect(fm8?.tags == ["telecom", "belgium"])
        #expect(fm8?.properties.first(where: { $0.key == "tags" })?.tags == ["telecom", "belgium"])
        #expect(fm8?.properties.first(where: { $0.key == "tags" })?.value == "telecom, belgium")
    }

    @Test func testFrontmatterParserWithoutFrontmatter() {
        let plain = """
        # Normal Markdown
        
        This note has no YAML frontmatter at all.
        ---
        A horizontal rule above.
        """
        let (fm, body) = FrontmatterParser.parse(plain)
        #expect(fm == nil)
        #expect(body == plain)
    }

    @Test func testVaultTagIndexingAndFiltering() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault_tags_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let vault = VaultManager(customVaultURL: tempDir)
        
        // Create 3 notes
        let note1 = """
        ---
        title: Note One
        tags: [tag-alpha, tag-beta]
        ---
        # Note One
        Content
        """
        try vault.createFile(relativePath: "NoteOne.md", content: note1)
        
        let note2 = """
        ---
        title: Note Two
        tags: [tag-alpha, tag-gamma]
        ---
        # Note Two
        Content
        """
        try vault.createFile(relativePath: "NoteTwo.md", content: note2)
        
        let note3 = """
        # Note Three
        Plain note with no tags.
        """
        try vault.createFile(relativePath: "NoteThree.md", content: note3)
        
        // 1. Verify tag aggregation in allTags
        #expect(vault.allTags["tag-alpha"] == 2)
        #expect(vault.allTags["tag-beta"] == 1)
        #expect(vault.allTags["tag-gamma"] == 1)
        #expect(vault.allTags["tag-delta"] == nil)
        
        // 2. Test getNotes(taggedWith:)
        let alphaNotes = vault.getNotes(taggedWith: "tag-alpha")
        #expect(alphaNotes.count == 2)
        #expect(alphaNotes.contains(where: { $0.relativePath == "NoteOne.md" }))
        #expect(alphaNotes.contains(where: { $0.relativePath == "NoteTwo.md" }))
        
        let betaNotes = vault.getNotes(taggedWith: "tag-beta")
        #expect(betaNotes.count == 1)
        #expect(betaNotes.first?.relativePath == "NoteOne.md")
        
        // 3. Test tag search
        let tagSearchResults = vault.searchNotes(query: "#tag-alpha")
        #expect(tagSearchResults.count == 2)
        #expect(tagSearchResults.contains(where: { $0.relativePath == "NoteOne.md" }))
    }

    @Test func testTerminalThemesRegistryIntegrity() {
        // 1. Total counts from terminalcolors.com
        #expect(TerminalThemes.all.count == 112)
        #expect(TerminalThemes.dark.count == 80)
        #expect(TerminalThemes.light.count == 32)
        #expect(TerminalThemes.families.count == 36)
        
        // 2. Validate all themes have valid hex colors and 16-color ANSI palettes
        for theme in TerminalThemes.all {
            #expect(!theme.id.isEmpty)
            #expect(!theme.displayName.isEmpty)
            #expect(!theme.themeFamily.isEmpty)
            #expect(theme.backgroundHex.hasPrefix("#"))
            #expect(theme.foregroundHex.hasPrefix("#"))
            #expect(theme.palette.count == 16)
            for color in theme.palette {
                #expect(color.hasPrefix("#"))
            }
            
            // Validate syntax theme mapping doesn't fail
            let syntaxTheme = theme.toSyntaxTheme()
            #expect(syntaxTheme.name == theme.displayName)
        }
        
        // 3. Check iconic theme families and variants
        let catppuccinMocha = TerminalThemes.byId["catppuccin-mocha"]
        #expect(catppuccinMocha != nil)
        #expect(catppuccinMocha?.isDark == true)
        #expect(catppuccinMocha?.backgroundHex == "#1e1e2e")
        
        let catppuccinLatte = TerminalThemes.byId["catppuccin-latte"]
        #expect(catppuccinLatte != nil)
        #expect(catppuccinLatte?.isDark == false)
        #expect(catppuccinLatte?.backgroundHex == "#eff1f5")
        
        let tokyoNight = TerminalThemes.byId["tokyo-night-default"]
        #expect(tokyoNight != nil)
        #expect(tokyoNight?.isDark == true)
        
        let tokyoNightDay = TerminalThemes.byId["tokyo-night-day"]
        #expect(tokyoNightDay != nil)
        #expect(tokyoNightDay?.isDark == false)
        
        let dracula = TerminalThemes.byId["dracula-default"]
        #expect(dracula != nil)
        #expect(dracula?.isDark == true)
        
        let nord = TerminalThemes.byId["nord-default"]
        #expect(nord != nil)
        #expect(nord?.isDark == true)
        
        let solarizedLight = TerminalThemes.byId["solarized-light"]
        #expect(solarizedLight != nil)
        #expect(solarizedLight?.isDark == false)
    }

    @Test func testThemeManagerResolution() {
        // 1. Clean UserDefaults test setup
        UserDefaults.standard.removeObject(forKey: ThemeManager.customThemeOverrideKey)
        UserDefaults.standard.removeObject(forKey: ThemeManager.appColorSchemeKey)
        UserDefaults.standard.set("catppuccin-mocha", forKey: ThemeManager.selectedDarkThemeIdKey)
        UserDefaults.standard.set("catppuccin-latte", forKey: ThemeManager.selectedLightThemeIdKey)
        
        // 2. Resolve for dark scheme
        let darkTheme = ThemeManager.resolveTheme(for: .dark)
        #expect(darkTheme.id == "catppuccin-mocha")
        #expect(darkTheme.isDark == true)
        
        // 3. Resolve for light scheme
        let lightTheme = ThemeManager.resolveTheme(for: .light)
        #expect(lightTheme.id == "catppuccin-latte")
        #expect(lightTheme.isDark == false)
        
        // 4. Custom theme override takes precedence regardless of environment
        UserDefaults.standard.set("nord-default", forKey: ThemeManager.customThemeOverrideKey)
        let overriddenTheme = ThemeManager.resolveTheme(for: .light)
        #expect(overriddenTheme.id == "nord-default")
        
        // Cleanup
        UserDefaults.standard.removeObject(forKey: ThemeManager.customThemeOverrideKey)
        UserDefaults.standard.removeObject(forKey: ThemeManager.selectedDarkThemeIdKey)
        UserDefaults.standard.removeObject(forKey: ThemeManager.selectedLightThemeIdKey)
    }

    @Test func testMarkdownSyntaxHighlighterAndNSTheme() {
        guard let draculaTheme = TerminalThemes.byId["dracula-default"] else {
            Issue.record("Dracula theme not found")
            return
        }
        
        let nsTheme = MarkdownNSTheme(theme: draculaTheme)
        #expect(nsTheme.name == "Dracula")
        #expect(nsTheme.heading != nsTheme.background)
        #expect(nsTheme.listMarker != nsTheme.background)
        #expect(nsTheme.code != nsTheme.background)
        
        let sampleMarkdown = """
        ---
        title: "Test Note"
        tags: [swift, unit-test]
        ---

        # My Main Title
        ## Subtitle Section

        - First item
        * Second item
        + Third item
        1. Numbered item

        - [ ] Unfinished task
        - [x] Completed task

        > A great quote goes here

        Here is some **bold text** and *italic text* and `let value = 42`.

        Check out [Brain.md](https://github.com/itsreidar/brain-md) or #release.
        """
        
        let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attributed = MarkdownSyntaxHighlighter.highlightToAttributedString(
            markdown: sampleMarkdown,
            theme: nsTheme,
            baseFont: baseFont
        )
        
        let string = attributed.string as NSString
        #expect(attributed.length == string.length)
        
        // 1. Verify Heading # marker and title attributes
        let h1HashRange = string.range(of: "#")
        #expect(h1HashRange.location != NSNotFound)
        if h1HashRange.location != NSNotFound {
            let attrs = attributed.attributes(at: h1HashRange.location, effectiveRange: nil)
            let color = attrs[.foregroundColor] as? NSColor
            #expect(color == nsTheme.headingMarker)
        }
        
        let h1TitleRange = string.range(of: "My Main Title")
        #expect(h1TitleRange.location != NSNotFound)
        if h1TitleRange.location != NSNotFound {
            let attrs = attributed.attributes(at: h1TitleRange.location, effectiveRange: nil)
            let color = attrs[.foregroundColor] as? NSColor
            let font = attrs[.font] as? NSFont
            #expect(color == nsTheme.heading)
            #expect(font != nil)
            #expect(font?.pointSize ?? 0 > baseFont.pointSize) // Heading scaled up
        }
        
        // 2. Verify List Marker
        let bulletRange = string.range(of: "- First")
        #expect(bulletRange.location != NSNotFound)
        if bulletRange.location != NSNotFound {
            let dashAttrs = attributed.attributes(at: bulletRange.location, effectiveRange: nil)
            let dashColor = dashAttrs[.foregroundColor] as? NSColor
            #expect(dashColor == nsTheme.listMarker)
        }
        
        // 3. Verify Numbered List
        let numRange = string.range(of: "1.")
        #expect(numRange.location != NSNotFound)
        if numRange.location != NSNotFound {
            let numAttrs = attributed.attributes(at: numRange.location, effectiveRange: nil)
            let numColor = numAttrs[.foregroundColor] as? NSColor
            #expect(numColor == nsTheme.number)
        }
        
        // 4. Verify Task Checkbox
        let taskRange = string.range(of: "[ ]")
        #expect(taskRange.location != NSNotFound)
        if taskRange.location != NSNotFound {
            let taskAttrs = attributed.attributes(at: taskRange.location, effectiveRange: nil)
            let taskColor = taskAttrs[.foregroundColor] as? NSColor
            #expect(taskColor == nsTheme.taskBox)
        }
        
        // 5. Verify Inline Code
        let codeRange = string.range(of: "`let value = 42`")
        #expect(codeRange.location != NSNotFound)
        if codeRange.location != NSNotFound {
            let codeAttrs = attributed.attributes(at: codeRange.location + 1, effectiveRange: nil)
            let codeColor = codeAttrs[.foregroundColor] as? NSColor
            let codeBg = codeAttrs[.backgroundColor] as? NSColor
            #expect(codeColor == nsTheme.code)
            #expect(codeBg != nil)
        }
        
        // 6. Verify Tag
        let tagRange = string.range(of: "#release")
        #expect(tagRange.location != NSNotFound)
        if tagRange.location != NSNotFound {
            let tagAttrs = attributed.attributes(at: tagRange.location, effectiveRange: nil)
            let tagColor = tagAttrs[.foregroundColor] as? NSColor
            #expect(tagColor == nsTheme.tag)
        }
        
        // 7. Verify Link
        let linkLabelRange = string.range(of: "Brain.md")
        #expect(linkLabelRange.location != NSNotFound)
        if linkLabelRange.location != NSNotFound {
            let linkAttrs = attributed.attributes(at: linkLabelRange.location, effectiveRange: nil)
            let linkColor = linkAttrs[.foregroundColor] as? NSColor
            let underline = linkAttrs[.underlineStyle] as? Int
            #expect(linkColor == nsTheme.link)
            #expect(underline == NSUnderlineStyle.single.rawValue)
        }
        
        // 8. Verify Blockquote
        let quoteRange = string.range(of: "A great quote goes here")
        #expect(quoteRange.location != NSNotFound)
        if quoteRange.location != NSNotFound {
            let quoteAttrs = attributed.attributes(at: quoteRange.location, effectiveRange: nil)
            let quoteColor = quoteAttrs[.foregroundColor] as? NSColor
            #expect(quoteColor == nsTheme.quote)
        }
        
        // 9. Verify Frontmatter Key
        let fmKeyRange = string.range(of: "title")
        #expect(fmKeyRange.location != NSNotFound)
        if fmKeyRange.location != NSNotFound {
            let fmAttrs = attributed.attributes(at: fmKeyRange.location, effectiveRange: nil)
            let fmKeyColor = fmAttrs[.foregroundColor] as? NSColor
            #expect(fmKeyColor == nsTheme.frontmatterKey)
        }
    }
}



