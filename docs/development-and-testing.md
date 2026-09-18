# Development & Testing Guide

This document covers the local development workflow, project structure, automated testing suite, and contribution guidelines for `brain-md`.

---

## Developer Prerequisites

- **Operating System**: macOS 14.0 (Sonoma) or macOS 15+ (Sequoia)
- **IDE**: Xcode 16.0 or newer
- **Language**: Swift 6.0 (Strict Concurrency enabled)
- **Command Line Tools**: `xcode-select --install`

---

## Repository Directory Map

```text
brain-md/
├── README.md                      # Public project landing page
├── LICENSE                        # GNU General Public License v3.0 (GPLv3)
├── docs/                          # Comprehensive technical guides
│   ├── architecture.md            # Concurrency & system design
│   ├── vault-management.md        # File storage & background watcher
│   ├── editor-and-markdown.md     # Syntax highlighting & Mermaid diagrams
│   ├── mcp-server.md              # Model Context Protocol API reference
│   ├── settings-and-customization.md # System settings & templates
│   └── development-and-testing.md # This guide
├── brain-md.xcodeproj             # Xcode project package
├── brain-md/                      # Main application source code
│   ├── brain_mdApp.swift          # App entrypoint (@main) & menu commands
│   ├── ContentView.swift          # Primary application window
│   ├── Models/                    # Data transfer objects & errors
│   │   ├── NoteItem.swift         # Directory node & file model
│   │   └── BrainError.swift       # Strongly-typed error domain
│   ├── Services/                  # Business logic & background workers
│   │   ├── VaultManager.swift     # File CRUD, selection, and monitor
│   │   ├── VaultManaging.swift    # Core protocol contract
│   │   ├── NoteTemplateEngine.swift # Title format & Markdown template engine
│   │   └── SyntaxHighlighter.swift # Custom regex syntax tokenizer
│   ├── Views/                     # SwiftUI views & UI components
│   │   ├── SidebarView.swift      # File tree navigation & drag-and-drop
│   │   ├── EditorSplitView.swift  # Dual-pane editor & live preview
│   │   ├── MarkdownEditorView.swift # Native AppKit text editing wrapper
│   │   ├── MarkdownPreviewView.swift# Rich formatted markdown renderer
│   │   ├── MermaidDiagramView.swift # Offline WKWebView diagram runner
│   │   ├── MCPServerModalView.swift # Server inspector & agent setup
│   │   └── SettingsView.swift     # macOS System Settings window
│   ├── MCP/                       # Model Context Protocol implementation
│   │   ├── MCPServer.swift        # JSON-RPC 2.0 tool execution engine
│   │   ├── MCPHTTPServer.swift    # HTTP listener & Server-Sent Events
│   │   ├── MCPStdioServer.swift   # Standard I/O subprocess transport
│   │   └── MCPTypes.swift         # Protocol schemas, requests, & responses
│   ├── Resources/                 # Static offline bundled assets
│   │   └── mermaid.min.js         # Bundled offline Mermaid.js engine
│   └── Assets.xcassets/           # App icon set & color assets
├── brain-mdTests/                 # Unit test suite (Swift Testing)
└── brain-mdUITests/               # Automated UI integration tests
```

---

## Building & Running

### Building from Xcode
1. Open `brain-md.xcodeproj` in Xcode.
2. Select the `brain-md` scheme with destination set to **My Mac**.
3. Press `⌘B` to build or `⌘R` to run.

### Building from the Terminal
```bash
# Debug Build
xcodebuild -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' build

# Release Build
xcodebuild -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -configuration Release build
```

---

## Automated Test Suite

`brain-md` uses Swift's modern `package:Testing` (`@Test`) framework with 15 comprehensive unit test suites:

```bash
xcodebuild test -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -only-testing:brain-mdTests
```

### Test Coverage Breakdown

| Test Name | Verifies |
| :--- | :--- |
| `testVaultCRUDAndSearch()` | File creation, UTF-8 reading, writing, appending, deletion, and full-text keyword search. |
| `testPathTraversalProtection()` | Attempts to pass `../../` escape sequences and verifies `BrainError.pathTraversalDetected` is thrown. |
| `testAnyCodableSubscriptsAndLiterals()` | Type erasure, dictionary indexing, and serialization for dynamic JSON-RPC parameters. |
| `testMCPServerProtocol()` | Proper dispatch of all 8 MCP tools (`list_notes`, `read_note`, `search_notes`, etc.). |
| `testMCPSingleLineJSONResponse()` | Enforces newline-delimited, single-line JSON formatting for SSE and Stdio clients. |
| `testSyntaxHighlighter()` | Tokenization of code blocks, headers, emphasis, lists, and inline links. |
| `testGFMBlockParsing()` | GFM callouts (`[!NOTE]`, `[!TIP]`), table syntax, and task lists. |
| `testMermaidDiagramSupport()` | Detection of ` ```mermaid ` code fences and SVG DOM container generation. |
| `testNewNoteAutoSwitchingAndUniqueNaming()` | Note collision prevention (`Untitled.md`, `Untitled 1.md`) and automatic selection switching. |
| `testDragAndDropNoteMoving()` | Moving notes between directories while preserving user selection. |
| `testFolderMoveAndRenamePreservesSelection()` | Recursive directory rename/move behavior and path preservation. |
| `testSettingsDefaultsAndAppStorage()` | Validation of default preferences across all 7 settings tabs. |
| `testNoteTemplateEngineTitlePresets()` | Presets (`untitled`, `date`, `journal`, `custom`), token parsing (`{date}`, `{time}`, `{year}`), and filename sanitization. |
| `testNoteTemplateEngineContentPresets()` | Content templates (`heading`, `dateHeading`, `journal`, `meeting`, `blank`, `custom`) and dynamic token substitution (`{{title}}`, `{{date}}`, `{{time}}`). |
| `testVaultCreateNoteFromTemplate()` | End-to-end integration creating notes on disk with active templates. |

---

## Code Quality & Architecture Guidelines

1. **Strict Concurrency**:
   - All shared state must be protected by `@MainActor` or encapsulated within thread-safe actor/isolation boundaries.
   - Avoid nonisolated references to actor properties in `deinit`.
2. **Zero Runtime Dependencies**:
   - Do not introduce external package dependencies (via Swift Package Manager or CocoaPods) unless strictly necessary. `brain-md` relies exclusively on Apple's standard frameworks (`SwiftUI`, `AppKit`, `WebKit`, `Network`, `Foundation`).
3. **Defensive Path Operations**:
   - Never use raw file paths without passing them through `resolveSecurePath(relativePath:)`.
4. **AppKit Integration**:
   - When AppKit window bridges (`NSViewRepresentable`) are used (such as `SettingsWindowConfigurator`), always wrap UI mutations in `@MainActor` and dispatch to the main queue.
