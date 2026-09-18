//
//  MCPServer.swift
//  brain-md
//

import Foundation

// MARK: - MCP Tool Definitions

public enum MCPToolName: String, CaseIterable, Sendable {
    case listNotes = "list_notes"
    case readNote = "read_note"
    case createNote = "create_note"
    case updateNote = "update_note"
    case deleteNote = "delete_note"
    case searchNotes = "search_notes"
    case getVaultStats = "get_vault_stats"
    case moveNote = "move_note"
}

// MARK: - MCPServing Protocol

@MainActor
public protocol MCPServing: AnyObject {
    func handleRequest(data: Data) async -> Data?
    func handle(request: JSONRPCRequest) -> JSONRPCResponse?
}

// MARK: - MCPServer Implementation

@MainActor
public final class MCPServer: MCPServing {
    public static let shared = MCPServer()
    
    private let vault: any VaultManaging
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    public init(vault: (any VaultManaging)? = nil) {
        self.vault = vault ?? VaultManager.shared
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }
    
    // MARK: - Process Incoming JSON-RPC Request
    
    public func handleRequest(data: Data) async -> Data? {
        // Strip carriage returns and leading/trailing whitespace
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D || last == 0x20 {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        
        guard let request = try? decoder.decode(JSONRPCRequest.self, from: trimmed) else {
            let errResp = JSONRPCResponse(id: nil, error: .parseError)
            return try? encoder.encode(errResp)
        }
        
        guard let response = handle(request: request) else { return nil }
        return try? encoder.encode(response)
    }
    
    public func handle(request: JSONRPCRequest) -> JSONRPCResponse? {
        let isNotification = (request.id == nil)
        
        switch request.method {
        case "initialize":
            let result: [String: AnyCodableValue] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [:],
                    "resources": [:],
                    "prompts": [:]
                ],
                "serverInfo": [
                    "name": "brain-md",
                    "version": "1.0.0"
                ]
            ]
            log(action: "MCP Initialize", detail: "Client connected")
            return JSONRPCResponse(id: request.id, result: .dictionary(result))
            
        case "notifications/initialized", "initialized":
            log(action: "MCP Handshake", detail: "Client initialized")
            return nil
            
        case "ping":
            return JSONRPCResponse(id: request.id, result: .dictionary([:]))
            
        case "prompts/list":
            return JSONRPCResponse(id: request.id, result: .dictionary(["prompts": .array([])]))
            
        case "resources/templates/list":
            return JSONRPCResponse(id: request.id, result: .dictionary(["resourceTemplates": .array([])]))
            
        case "logging/setLevel":
            return JSONRPCResponse(id: request.id, result: .dictionary([:]))
            
        case "completion/complete":
            return JSONRPCResponse(id: request.id, result: .dictionary(["completion": .dictionary(["values": .array([])])]))
            
        case "tools/list":
            let tools = getAvailableTools()
            let toolsArray: [AnyCodableValue] = tools.map { tool in
                AnyCodableValue.dictionary([
                    "name": AnyCodableValue.string(tool.name),
                    "description": AnyCodableValue.string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            }
            return JSONRPCResponse(id: request.id, result: .dictionary(["tools": .array(toolsArray)]))
            
        case "tools/call":
            guard let params = request.params,
                  let toolName = params["name"]?.stringValue else {
                return JSONRPCResponse(id: request.id, error: .invalidParams)
            }
            let arguments = params["arguments"]?.dictValue ?? [:]
            let toolResult = executeTool(name: toolName, arguments: arguments)
            
            let contentsArray: [AnyCodableValue] = toolResult.content.map { c in
                AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string(c.type),
                    "text": AnyCodableValue.string(c.text)
                ])
            }
            let resDict: [String: AnyCodableValue] = [
                "content": .array(contentsArray),
                "isError": .bool(toolResult.isError)
            ]
            return JSONRPCResponse(id: request.id, result: .dictionary(resDict))
            
        case "resources/list":
            let resources = getAvailableResources()
            let resArray: [AnyCodableValue] = resources.map { r in
                var dict: [String: AnyCodableValue] = [
                    "uri": .string(r.uri),
                    "name": .string(r.name)
                ]
                if let d = r.description { dict["description"] = .string(d) }
                if let m = r.mimeType { dict["mimeType"] = .string(m) }
                return .dictionary(dict)
            }
            return JSONRPCResponse(id: request.id, result: .dictionary(["resources": .array(resArray)]))
            
        case "resources/read":
            guard let params = request.params,
                  let uri = params["uri"]?.stringValue else {
                return JSONRPCResponse(id: request.id, error: .invalidParams)
            }
            let result = readResource(uri: uri)
            return JSONRPCResponse(id: request.id, result: result)
            
        default:
            if isNotification || request.method.starts(with: "notifications/") || request.method.starts(with: "$/") {
                return nil
            }
            return JSONRPCResponse(id: request.id, error: .methodNotFound)
        }
    }
    
    // MARK: - Tool Definitions
    
    public func getAvailableTools() -> [MCPTool] {
        return [
            MCPTool(
                name: MCPToolName.listNotes.rawValue,
                description: "List notes in the vault, optionally filtered by folder.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "folder": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Optional subfolder to list from")
                        ])
                    ])
                ])
            ),
            MCPTool(
                name: MCPToolName.readNote.rawValue,
                description: "Read the full Markdown content of a specific note.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "path": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Relative path to the note (e.g., 'Welcome to Brain-md.md')")
                        ])
                    ]),
                    "required": AnyCodableValue.array([AnyCodableValue.string("path")])
                ])
            ),
            MCPTool(
                name: MCPToolName.createNote.rawValue,
                description: "Create a new markdown note in the vault.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "path": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Relative path for the new note, including folder if applicable")
                        ]),
                        "content": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Markdown formatted content of the note")
                        ])
                    ]),
                    "required": AnyCodableValue.array([
                        AnyCodableValue.string("path"),
                        AnyCodableValue.string("content")
                    ])
                ])
            ),
            MCPTool(
                name: MCPToolName.updateNote.rawValue,
                description: "Update the content of an existing note (overwrite or append).",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "path": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Relative path to the note")
                        ]),
                        "content": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("New content to write or append")
                        ]),
                        "mode": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Write mode: 'overwrite' (default) or 'append'")
                        ])
                    ]),
                    "required": AnyCodableValue.array([
                        AnyCodableValue.string("path"),
                        AnyCodableValue.string("content")
                    ])
                ])
            ),
            MCPTool(
                name: MCPToolName.deleteNote.rawValue,
                description: "Permanently delete a note from the vault.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "path": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Relative path of the note to delete")
                        ])
                    ]),
                    "required": AnyCodableValue.array([AnyCodableValue.string("path")])
                ])
            ),
            MCPTool(
                name: MCPToolName.searchNotes.rawValue,
                description: "Search for text or keywords across all markdown notes in the vault.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "query": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Keyword or substring to search for")
                        ])
                    ]),
                    "required": AnyCodableValue.array([AnyCodableValue.string("query")])
                ])
            ),
            MCPTool(
                name: MCPToolName.getVaultStats.rawValue,
                description: "Get vault statistics including total note count, total word count, and vault path.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([:])
                ])
            ),
            MCPTool(
                name: MCPToolName.moveNote.rawValue,
                description: "Move a note or folder into another folder or the vault root.",
                inputSchema: AnyCodableValue.dictionary([
                    "type": AnyCodableValue.string("object"),
                    "properties": AnyCodableValue.dictionary([
                        "sourcePath": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Current relative path of the note or folder")
                        ]),
                        "targetFolder": AnyCodableValue.dictionary([
                            "type": AnyCodableValue.string("string"),
                            "description": AnyCodableValue.string("Destination folder relative path, or empty string for vault root")
                        ])
                    ]),
                    "required": AnyCodableValue.array([AnyCodableValue.string("sourcePath")])
                ])
            )
        ]
    }
    
    // MARK: - Tool Execution
    
    private func executeTool(name: String, arguments: [String: AnyCodableValue]) -> MCPToolResult {
        log(action: "Tool Call: \(name)", detail: "\(arguments)")
        
        guard let tool = MCPToolName(rawValue: name) else {
            return MCPToolResult(text: BrainError.unknownTool(name: name).localizedDescription, isError: true)
        }
        
        switch tool {
        case .listNotes:
            return handleListNotes(args: arguments)
        case .readNote:
            return handleReadNote(args: arguments)
        case .createNote:
            return handleCreateNote(args: arguments)
        case .updateNote:
            return handleUpdateNote(args: arguments)
        case .deleteNote:
            return handleDeleteNote(args: arguments)
        case .searchNotes:
            return handleSearchNotes(args: arguments)
        case .getVaultStats:
            return handleGetStats()
        case .moveNote:
            return handleMoveNote(args: arguments)
        }
    }
    
    private func handleListNotes(args: [String: AnyCodableValue]) -> MCPToolResult {
        let paths = vault.getAllNotePaths()
        let folder = args["folder"]?.stringValue
        
        let filtered = paths.filter { path in
            guard let f = folder, !f.isEmpty else { return true }
            return path.hasPrefix(f)
        }
        
        let isoFormatter = ISO8601DateFormatter()
        let items: [NoteListingItem] = filtered.map { path in
            let itemURL = vault.vaultURL.appendingPathComponent(path)
            let size = (try? itemURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let modDate = (try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return NoteListingItem(
                path: path,
                sizeBytes: Int64(size),
                lastModified: isoFormatter.string(from: modDate)
            )
        }
        
        if let json = try? encoder.encode(items), let str = String(data: json, encoding: .utf8) {
            return MCPToolResult(text: str)
        }
        return MCPToolResult(text: "[]")
    }
    
    private func handleReadNote(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let path = args["path"]?.stringValue else {
            return MCPToolResult(text: BrainError.invalidToolArgument(tool: "read_note", argument: "path").localizedDescription, isError: true)
        }
        do {
            let content = try vault.readFile(relativePath: path)
            return MCPToolResult(text: content)
        } catch {
            return MCPToolResult(text: error.localizedDescription, isError: true)
        }
    }
    
    private func handleCreateNote(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let path = args["path"]?.stringValue,
              let content = args["content"]?.stringValue else {
            return MCPToolResult(text: BrainError.invalidToolArgument(tool: "create_note", argument: "path/content").localizedDescription, isError: true)
        }
        do {
            try vault.createFile(relativePath: path, content: content)
            return MCPToolResult(text: "Successfully created note at '\(path)'")
        } catch {
            return MCPToolResult(text: error.localizedDescription, isError: true)
        }
    }
    
    private func handleUpdateNote(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let path = args["path"]?.stringValue,
              let content = args["content"]?.stringValue else {
            return MCPToolResult(text: BrainError.invalidToolArgument(tool: "update_note", argument: "path/content").localizedDescription, isError: true)
        }
        let mode = args["mode"]?.stringValue ?? "overwrite"
        do {
            if mode == "append" {
                try vault.appendFile(relativePath: path, contentToAppend: content)
                return MCPToolResult(text: "Successfully appended to '\(path)'")
            } else {
                try vault.writeFile(relativePath: path, content: content)
                return MCPToolResult(text: "Successfully updated '\(path)'")
            }
        } catch {
            return MCPToolResult(text: error.localizedDescription, isError: true)
        }
    }
    
    private func handleDeleteNote(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let path = args["path"]?.stringValue else {
            return MCPToolResult(text: BrainError.invalidToolArgument(tool: "delete_note", argument: "path").localizedDescription, isError: true)
        }
        do {
            try vault.deleteFile(relativePath: path)
            return MCPToolResult(text: "Successfully deleted '\(path)'")
        } catch {
            return MCPToolResult(text: error.localizedDescription, isError: true)
        }
    }
    
    private func handleSearchNotes(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let query = args["query"]?.stringValue else {
            return MCPToolResult(text: BrainError.invalidToolArgument(tool: "search_notes", argument: "query").localizedDescription, isError: true)
        }
        let results = vault.searchNotes(query: query)
        let items = results.map { r in
            SearchResultItem(
                path: r.relativePath,
                title: r.title,
                snippet: r.snippet,
                line: r.matchLine
            )
        }
        if let json = try? encoder.encode(items), let str = String(data: json, encoding: .utf8) {
            return MCPToolResult(text: str)
        }
        return MCPToolResult(text: "[]")
    }
    
    private func handleGetStats() -> MCPToolResult {
        let stats = vault.getStats()
        let path = stats["vaultPath"]?.stringValue ?? vault.vaultURL.path
        let count = stats["totalNotes"]?.intValue ?? 0
        let words = stats["totalWords"]?.intValue ?? 0
        let recent = stats["recentNotes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        
        let statsItem = VaultStatsItem(
            vaultPath: path,
            totalNotes: count,
            totalWords: words,
            recentNotes: recent
        )
        
        if let json = try? encoder.encode(statsItem), let str = String(data: json, encoding: .utf8) {
            return MCPToolResult(text: str)
        }
        return MCPToolResult(text: "{}")
    }
    
    private func handleMoveNote(args: [String: AnyCodableValue]) -> MCPToolResult {
        guard let source = args["sourcePath"]?.stringValue else {
            return MCPToolResult(text: "Missing required argument 'sourcePath'.", isError: true)
        }
        let target = args["targetFolder"]?.stringValue ?? ""
        do {
            try vault.moveItem(sourceRelativePath: source, toDirectoryRelativePath: target)
            return MCPToolResult(text: "Successfully moved '\(source)' into '\(target.isEmpty ? "vault root" : target)'.")
        } catch {
            return MCPToolResult(text: "Move failed: \(error.localizedDescription)", isError: true)
        }
    }
    
    // MARK: - Resources
    
    public func getAvailableResources() -> [MCPResource] {
        let paths = vault.getAllNotePaths()
        return paths.map { path in
            MCPResource(
                uri: "note://\(path)",
                name: (path as NSString).lastPathComponent,
                description: "Markdown note: \(path)",
                mimeType: "text/markdown"
            )
        }
    }
    
    public func readResource(uri: String) -> AnyCodableValue {
        guard uri.hasPrefix("note://") else {
            return .dictionary(["error": .string(BrainError.invalidResourceScheme(uri: uri).localizedDescription)])
        }
        let relativePath = String(uri.dropFirst("note://".count))
        guard let content = try? vault.readFile(relativePath: relativePath) else {
            return .dictionary(["error": .string(BrainError.resourceNotFound(uri: uri).localizedDescription)])
        }
        
        return .dictionary([
            "contents": .array([
                .dictionary([
                    "uri": .string(uri),
                    "mimeType": .string("text/markdown"),
                    "text": .string(content)
                ])
            ])
        ])
    }
    
    private func log(action: String, detail: String) {
        vault.logActivity(action: action, detail: detail, isError: false)
    }
}
