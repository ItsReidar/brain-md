# Model Context Protocol (MCP) Server Guide

This document details the embedded **Model Context Protocol (MCP)** server within `brain-md`, its communication transports, and its complete tool API reference.

---

## What is MCP?

The [Model Context Protocol (MCP)](https://modelcontextprotocol.io) is an open standard developed by Anthropic that allows AI models (like Claude, Gemini, and GPT-4) to securely interact with local applications and data sources through standardized tools, resources, and prompts.

By running an embedded MCP server inside `brain-md`, external AI coding assistants and autonomous agents can:
- Directly query and read notes from your personal knowledge base.
- Conduct full-text searches across your notes.
- Automatically log meeting notes, code snippets, and research summaries.
- Reorganize files and directories in your vault.

---

## Server Architecture & Transports

`brain-md` supports dual transports for maximum client compatibility:

```mermaid
graph LR
    subgraph Clients ["AI Clients & Agents"]
        Claude["Claude Desktop"]
        Cursor["Cursor IDE"]
        Terminal["CLI / curl / Agent Scripts"]
    end

    subgraph Transports ["MCP Transports"]
        SSE["HTTP Server-Sent Events (GET /sse)"]
        HTTPMsg["HTTP Message Endpoint (POST /messages)"]
        Stdio["Standard Input / Output (stdin/stdout)"]
    end

    subgraph Server ["brain-md Core Engine"]
        MCPEngine["MCPServer (JSON-RPC 2.0 Engine)"]
        VM["VaultManager"]
        Disk[("Vault Files (.md)")]
    end

    Claude <-->|Stream events & tools| SSE
    Claude <-->|Send JSON-RPC requests| HTTPMsg
    Cursor <-->|Direct subprocess interop| Stdio
    Terminal <-->|curl / scripts| HTTPMsg

    SSE --> MCPEngine
    HTTPMsg --> MCPEngine
    Stdio --> MCPEngine
    MCPEngine <--> VM
    VM <--> Disk
```

### 1. HTTP & Server-Sent Events (SSE)
- **Port**: Default is `8765` (configurable in **Settings > MCP Server**).
- **SSE Stream**: `GET http://127.0.0.1:8765/sse` maintains a persistent event stream.
- **Message Endpoint**: `POST http://127.0.0.1:8765/messages` accepts standard JSON-RPC 2.0 payloads.

### 2. Standard Input/Output (Stdio)
- For local process-based integration (e.g. command-line CLI invocations), `MCPStdioServer` processes line-delimited JSON-RPC requests on `stdin` and writes formatted single-line JSON responses on `stdout`.

---

## Agent Request Lifecycle

```mermaid
sequenceDiagram
    autonumber
    participant Agent as AI Agent (e.g. Claude)
    participant HTTP as MCPHTTPServer
    participant MCP as MCPServer
    participant Vault as VaultManager
    participant Disk as Local Filesystem

    Agent->>HTTP: POST /messages (method: "tools/call", name: "search_notes")
    HTTP->>MCP: Decodes JSONRPCRequest
    MCP->>MCP: Checks read-only protection & sanitizes arguments
    MCP->>Vault: searchNotes(query: "swiftui architecture")
    Vault->>Disk: Reads & searches markdown files
    Disk-->>Vault: Returns matching items
    Vault-->>MCP: [NoteSearchResult]
    MCP->>MCP: Formats MCPToolResult (JSON)
    MCP-->>HTTP: Encodes single-line JSONRPCResponse
    HTTP-->>Agent: 200 OK (Content-Type: application/json)
```

---

## Complete MCP Tool Reference

`brain-md` exposes 16 native tools. With **Read-Only** on in Settings › MCP Server, the six that change the vault (`create_note`, `update_note`, `delete_note`, `move_note`, `create_folder`, `rename_note`) are refused with an error before anything on disk changes; the others keep working.

### 1. `list_notes`
Lists all Markdown notes and directories in the vault.
- **Arguments**:
  - `path` *(string, optional)*: Relative directory path to list. Defaults to vault root.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "list_notes",
      "arguments": { "path": "Research" }
    }
  }
  ```

---

### 2. `read_note`
Reads the raw Markdown content of a specific note.
- **Arguments**:
  - `path` *(string, required)*: Relative path to the `.md` file.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "read_note",
      "arguments": { "path": "Project Ideas.md" }
    }
  }
  ```

---

### 3. `create_note`
Creates a new Markdown note in the vault. Automatically creates intermediate folders if needed.
- **Arguments**:
  - `path` *(string, required)*: Relative path for the new note (e.g. `Meetings/2026-09-18.md`).
  - `content` *(string, required)*: Markdown body content.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "create_note",
      "arguments": {
        "path": "Research/AI Protocols.md",
        "content": "# AI Protocols\n\nNotes on MCP and agents.\n"
      }
    }
  }
  ```

---

### 4. `update_note`
Appends to or overwrites an existing note.
- **Arguments**:
  - `path` *(string, required)*: Relative path to the note.
  - `content` *(string, required)*: Markdown content to write or append.
  - `mode` *(string, optional)*: `"overwrite"` (default) or `"append"`.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "update_note",
      "arguments": {
        "path": "Journal/Daily Log.md",
        "content": "\n- Completed code review at 15:00\n",
        "mode": "append"
      }
    }
  }
  ```

---

### 5. `delete_note`
Moves a note from the vault to the macOS Trash, where Finder's **Put Back** restores it.
- **Arguments**:
  - `path` *(string, required)*: Relative path to the note to delete.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "delete_note",
      "arguments": { "path": "Old Scratchpad.md" }
    }
  }
  ```

---

### 6. `search_notes`
Performs a fast, case-insensitive full-text and title search across all notes in the vault.
- **Arguments**:
  - `query` *(string, required)*: Search keyword or phrase.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 6,
    "method": "tools/call",
    "params": {
      "name": "search_notes",
      "arguments": { "query": "database schema" }
    }
  }
  ```

---

### 7. `get_vault_stats`
Returns summary statistics about the vault, including total note count, total word count, total storage size on disk, and recent activity logs.
- **Arguments**: None.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 7,
    "method": "tools/call",
    "params": {
      "name": "get_vault_stats",
      "arguments": {}
    }
  }
  ```

---

### 8. `move_note`
Renames a note or moves it to a new subdirectory within the vault.
- **Arguments**:
  - `sourcePath` *(string, required)*: Current relative path of the note.
  - `destinationPath` *(string, required)*: New relative path or directory.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 8,
    "method": "tools/call",
    "params": {
      "name": "move_note",
      "arguments": {
        "sourcePath": "Drafts/Spec.md",
        "destinationPath": "Archived/Spec.md"
      }
    }
  }
  ```

### 9. `get_tags`
Lists all tags across notes in the vault, with occurrence count and associated matching note paths.
- **Arguments**:
  - `tag` *(string, optional)*: Specific tag to query (with or without `#`). Omit to list all tags.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 9,
    "method": "tools/call",
    "params": {
      "name": "get_tags",
      "arguments": {
        "tag": "swift"
      }
    }
  }
  ```

### 10. `get_backlinks`
Resolves incoming backlinks, outgoing links (wikilinks `[[Note]]` and Markdown links `[text](Note.md)`), and tags for a specific note.
- **Arguments**:
  - `path` *(string, required)*: Relative path to the target note.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 10,
    "method": "tools/call",
    "params": {
      "name": "get_backlinks",
      "arguments": {
        "path": "Welcome to Brain-md.md"
      }
    }
  }
  ```

### 11. `create_folder`
Creates a folder in the vault, including any missing parent folders. Succeeds if the folder already exists.
- **Arguments**:
  - `path` *(string, required)*: Relative path of the folder (e.g., `Projects/2026`).
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 11,
    "method": "tools/call",
    "params": {
      "name": "create_folder",
      "arguments": {
        "path": "Projects/2026"
      }
    }
  }
  ```

### 12. `rename_note`
Renames a note or folder in place. A note keeps its extension when the new name leaves it out.
- **Arguments**:
  - `path` *(string, required)*: Relative path of the note or folder.
  - `newName` *(string, required)*: The new name, without a folder.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 12,
    "method": "tools/call",
    "params": {
      "name": "rename_note",
      "arguments": { "path": "Inbox/Draft.md", "newName": "Meeting 2026-10-13" }
    }
  }
  ```

### 13. `list_folders`
Lists every folder in the vault, including empty ones (`list_notes` only lists notes). Returns a JSON array of relative paths.
- **Arguments**:
  - None.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 13,
    "method": "tools/call",
    "params": {
      "name": "list_folders",
      "arguments": {}
    }
  }
  ```

### 14. `search_by_meaning`
Searches notes by meaning instead of exact words, with Brain.md's on-device embedding model, also across languages. Returns the closest notes, best first, with the matching passage and a score. Needs a search model downloaded in **Settings › Local AI & Voice › Semantic Search**; without one it returns an error saying so. The first search indexes the vault, later ones only embed changed notes.
- **Arguments**:
  - `query` *(string, required)*: What you're looking for, in plain words.
  - `limit` *(integer, optional)*: Maximum notes to return, 1–50 (default 10).
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 14,
    "method": "tools/call",
    "params": {
      "name": "search_by_meaning",
      "arguments": { "query": "budget overrun", "limit": 5 }
    }
  }
  ```

### 15. `get_open_note`
Returns the note open in Brain.md's front tab: path, title, content including edits not saved yet, and whether it's outside the vault. Needs the Brain.md app (connect over HTTP); the `--stdio` server has no window and returns an error.
- **Arguments**:
  - None.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 15,
    "method": "tools/call",
    "params": {
      "name": "get_open_note",
      "arguments": {}
    }
  }
  ```

### 16. `open_note`
Opens a note in Brain.md for the user to see, in a new tab by default; a note that's already open in a tab comes to the front. Needs the Brain.md app (HTTP), not `--stdio`. Allowed in read-only mode, since it changes nothing on disk.
- **Arguments**:
  - `path` *(string, required)*: Relative path of the note.
  - `newTab` *(boolean, optional)*: `true` (default) for a new tab, `false` to show it in the front tab.
- **Example Call**:
  ```json
  {
    "jsonrpc": "2.0",
    "id": 16,
    "method": "tools/call",
    "params": {
      "name": "open_note",
      "arguments": { "path": "Projects/Plan.md" }
    }
  }
  ```

---

## Testing via cURL

You can test the MCP HTTP server directly from your macOS terminal:

```bash
# 1. Initialize MCP session
curl -X POST http://127.0.0.1:8765/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0"}}}'

# 2. List available tools
curl -X POST http://127.0.0.1:8765/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'

# 3. Call search_notes
curl -X POST http://127.0.0.1:8765/messages \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"welcome"}}}'
```
