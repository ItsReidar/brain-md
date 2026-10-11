# Development & Testing Guide

This document covers the local development workflow, project structure, automated testing suite, and contribution guidelines for `brain-md`.

---

## Developer Prerequisites

- **Operating System**: macOS 26 (Tahoe) or later; Apple Silicon for on-device AI
- **IDE**: Xcode 26 or newer, with the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- **Language**: Swift 6.0 (Strict Concurrency enabled)
- **Command Line Tools**: `xcode-select --install`

---

## Repository Directory Map

```text
brain-md/
├── README.md                      # Public project landing page
├── LICENSE                        # GNU General Public License v3.0 (GPLv3)
├── assets/                        # Public media, branding, and app icon
│   └── app-icon.png               # High-resolution macOS app icon (256x256 RGBA)
├── docs/                          # Comprehensive technical guides
│   ├── architecture.md            # Concurrency & system design
│   ├── vault-management.md        # File storage & background watcher
│   ├── editor-and-markdown.md     # Syntax highlighting & Mermaid diagrams
│   ├── mcp-server.md              # Model Context Protocol API reference
│   ├── settings-and-customization.md # System settings & templates
│   ├── 3d-graph-view.md           # SceneKit brain graph & layout model
│   ├── local-ai.md                # Models, skills, chat & meeting transcription
│   ├── finder-integration.md      # Opening files from Finder & Quick Look
│   ├── releasing.md               # DMG, signing & Homebrew cask
│   ├── release-notes/             # Per-version notes used by publish.sh
│   └── development-and-testing.md # This guide
├── scripts/release/               # package.sh & publish.sh (see releasing.md)
├── scripts/models/                # Model conversion (convert_orukeet.py)
├── Config/                        # Info.plist keys merged into the app's generated Info.plist
├── packaging/homebrew/            # Cask template
├── brain-md.xcodeproj             # Xcode project package
├── brain-md/                      # Main application source code
│   ├── brain_mdApp.swift          # App entrypoint (@main) & menu commands
│   ├── ContentView.swift          # Primary application window
│   ├── Models/                    # Data transfer objects & errors
│   │   ├── NoteItem.swift         # Directory node & file model
│   │   ├── Frontmatter.swift      # YAML frontmatter parser
│   │   ├── LocalAIModels.swift    # AI request, transcript & capture types
│   │   ├── TerminalTheme.swift    # Editor/code color themes
│   │   └── BrainError.swift       # Strongly-typed error domain
│   ├── Services/                  # Business logic & background workers
│   │   ├── VaultManager.swift     # File CRUD, selection, and monitor
│   │   ├── VaultAppFolders.swift  # Skills & attachments as app folders (sidebar, graph)
│   │   ├── VaultManaging.swift    # Core protocol contract
│   │   ├── NoteTemplateEngine.swift # Title format & Markdown template engine
│   │   ├── SyntaxHighlighter.swift # Custom regex syntax tokenizer
│   │   ├── NoteGraphService.swift # Graph link extraction & 3D force simulation
│   │   ├── ScrollSyncCoordinator.swift # Bidirectional scroll synchronizer
│   │   ├── MarkdownFormatService.swift # Format menu commands (bold, headings, …)
│   │   ├── PDFExportService.swift # Vector PDF export of the preview
│   │   ├── ThemeManager.swift     # Theme selection & syntax colors
│   │   └── AI/                    # On-device AI & meetings (see local-ai.md)
│   │       ├── Models/            # ModelCatalog, ModelStore, ModelSelection, LanguageModelRuntime
│   │       ├── Speech/            # Speech engines, utterance segmenter, Sortformer diarizer
│   │       ├── Vendor/Gemma4Audio/ # Gemma 4 audio input ported from mlx-swift-lm#392
│   │       ├── HubAdapters.swift  # Hugging Face/tokenizer bridges, KV-cache mask fix
│   │       ├── LanguageModelService.swift # Prompts & streaming generation
│   │       ├── AssistantChat.swift    # Free-form chat state & history replay
│   │       ├── Skills.swift       # Skill files, prompts & the vault's skill library
│   │       ├── VisualCaptureService.swift # Screenshots for Explain Screen
│   │       ├── AudioCaptureService.swift # System audio + microphone capture
│   │       └── MeetingRecorder.swift # Recording session & transcript lines
│   ├── Views/                     # SwiftUI views & UI components
│   │   ├── SidebarView.swift      # File tree navigation & drag-and-drop
│   │   ├── EditorSplitView.swift  # Dual-pane editor & live preview with SplitDivider
│   │   ├── MarkdownEditorView.swift # Native AppKit text editing wrapper
│   │   ├── MarkdownPreviewView.swift# Rich formatted markdown renderer
│   │   ├── MermaidDiagramView.swift # Offline WKWebView diagram runner
│   │   ├── BrainGraphModalView.swift # 3D knowledge graph modal
│   │   ├── BrainGraph3DView.swift # SceneKit 3D brain network view (Graph3DSceneView)
│   │   ├── QuickSwitcherModalView.swift # Spotlight-style note switcher (⌘O)
│   │   ├── MCPServerModalView.swift # Server inspector & agent setup
│   │   ├── AIResultSheet.swift    # Review sheet for model output
│   │   ├── AssistantChatView.swift # "AI Chat" window
│   │   ├── ModelSettingsViews.swift # Model rows in Settings
│   │   ├── MeetingLiveOverlay.swift # Live levels & partial transcript
│   │   └── SettingsView.swift     # macOS System Settings window
│   ├── MCP/                       # Model Context Protocol implementation
│   │   ├── MCPServer.swift        # JSON-RPC 2.0 tool execution engine
│   │   ├── MCPHTTPServer.swift    # HTTP listener & Server-Sent Events
│   │   ├── MCPStdioServer.swift   # Standard I/O subprocess transport
│   │   └── MCPTypes.swift         # Protocol schemas, requests, & responses
│   ├── Resources/                 # Static offline bundled assets
│   │   ├── mermaid.min.js         # Bundled offline Mermaid.js engine
│   │   └── TerminalThemes.swift   # Built-in color theme definitions
│   └── Assets.xcassets/           # App icon set & color assets
├── brain-md-QuickLook/            # Finder Quick Look preview extension (shares the app's renderer)
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

`brain-md` uses Swift's modern `package:Testing` (`@Test`) framework with comprehensive unit test coverage:

```bash
xcodebuild test -project brain-md.xcodeproj -scheme brain-md -destination 'platform=macOS' -only-testing:brain-mdTests
```

### Test Coverage Breakdown

| Test Name | Verifies |
| :--- | :--- |
| `testVaultCRUDAndSearch()` | File creation, UTF-8 reading, writing, appending, deletion, and full-text keyword search. |
| `testPathTraversalProtection()` | Attempts to pass `../../` escape sequences and verifies `BrainError.pathTraversalDetected` is thrown. |
| `testAnyCodableSubscriptsAndLiterals()` | Type erasure, dictionary indexing, and serialization for dynamic JSON-RPC parameters. |
| `testMCPServerProtocol()` | Proper dispatch of core MCP tools (`list_notes`, `read_note`, `search_notes`, etc.). |
| `testMCPGetTagsTool()` | Global tag collection (`#tag` scanning across all vault notes) with count and note list verification. |
| `testMCPGetBacklinksTool()` | Bidirectional wikilink resolver returning all referencing notes for a target note. |
| `testMCPSingleLineJSONResponse()` | Enforces newline-delimited, single-line JSON formatting for SSE and Stdio clients. |
| `testSyntaxHighlighter()` | Tokenization of code blocks, headers, emphasis, lists, and inline links. |
| `testGFMBlockParsing()` | GFM callouts (`[!NOTE]`, `[!TIP]`), table syntax, and task lists. |
| `testMermaidDiagramSupport()` | Detection of ` ```mermaid ` code fences and SVG DOM container generation. |
| `testNewNoteAutoSwitchingAndUniqueNaming()` | Note collision prevention (`Untitled.md`, `Untitled 1.md`) and automatic selection switching. |
| `testDragAndDropNoteMoving()` | Moving notes between directories while preserving user selection. |
| `testFolderMoveAndRenamePreservesSelection()` | Recursive directory rename/move behavior and path preservation. |
| `testSplitDividerRatioClampingAndWidths()` | Proportion clamping (0.20–0.80) and panel width calculations across drag interactions. |
| `testSettingsDefaultsAndAppStorage()` | Validation of default preferences across all settings tabs. |
| `testNoteTemplateEngineTitlePresets()` | Presets (`untitled`, `date`, `journal`, `custom`), token parsing (`{date}`, `{time}`, `{year}`), and filename sanitization. |
| `testNoteTemplateEngineContentPresets()` | Content templates (`heading`, `dateHeading`, `journal`, `meeting`, `blank`, `custom`) and dynamic token substitution (`{{title}}`, `{{date}}`, `{{time}}`). |
| `testVaultCreateNoteFromTemplate()` | End-to-end integration creating notes on disk with active templates. |
| `testScrollProgressCalculation()` | Proportional scroll calculation across mid-range, boundaries, rubber-band overscroll, and short content. |
| `testTargetOffsetCalculation()` | Precise target coordinate mapping and clamping for peer scroll views. |
| `testCoordinatorSyncToggleAndRegistration()` | Observer lifecycle, listener registration/unregistration, and sync toggling. |
| `testReentrantSafeBidirectionalSync()` | Synchronous re-entrancy isolation preventing echo feedback loops and enabling lag-free bidirectional tracking. |
| `testRegistrationIdempotency()` | Ensures repeated view-tree registrations are safely deduplicated. |
| `testBottomOverscrollClamping()` | Prevents overscroll rubber-banding from overflowing peer view bounds. |
| `testEffectiveContentHeightForNSTextView()` | Queries TextKit layout manager `usedRect` rather than stale/bloated `bounds.height`. |
| `testSyncScrollWithBloatedNSTextViewDoesNotScrollIntoVoid()` | Verifies editor text stays pinned within valid bounds without scrolling into empty void. |
| `testSwiftUIScrollViewFlippedness()` | Validates coordinate flip conventions and layout metrics for SwiftUI `ScrollView` hosts. |
| `testSimulatedScrollDownAndUp()` | Simulates full down-and-up scroll cycles ensuring follower tracks smoothly in both directions. |
| `testRealViewsScrollSyncBidirectional()` | Integration test with live `MarkdownNSTextView` and `MarkdownPreviewView` in an `NSWindow`. |
| `testEditorDocumentViewStartsAtClipOrigin()` | Regression: the editor's text view frame origin stays at zero (text laid out before attachment used to push it to y ≈ -8000). |
| `testSplitHierarchyAutoRegistersBothPanes()` | The real split hierarchy registers editor and preview with `ScrollSyncCoordinator.shared` without manual wiring. |
| `testNotificationDrivenSync()` | End-to-end sync in both directions through live-scroll and bounds notifications only. |
| `testPreviewElasticOverscrollNeverPushesEditorIntoVoid()` | Elastic overscroll past either end of the preview pins the editor to its text bounds. |
| `testFollowerBoundsChangeIgnoredWhileOtherPaneDrives()` | Bounds changes on the follower are ignored while the other pane owns a live scroll. |
| `testLayoutChangeDoesNotDriveEditor()` | Layout-driven preview bounds changes (re-render while typing) never move the editor. |
| `testUnregisterOnlyMatchingScrollView()` | Identity-checked unregistration survives SwiftUI building replacements before dismantling. |
| `testScrollViewFinderRegistersAndReleasesPreview()` | `ScrollViewFinder` registers on window attach and unregisters on dismantle. |
| `testMetricsIgnoreDocumentFrameOrigin()` / `testMetricsNonFlippedDocument()` / `testMetricsHonorContentInsets()` / `testMetricsShortDocument()` | `ScrollMetrics` geometry: frame-origin independence, `isFlipped` handling, content insets, and non-scrollable documents. |
| `ModelStoreTests` | Snapshot completeness (every indexed weight file), legacy placeholder cleanup, disk size of symlinked blobs, memory check, and loading without a download. |
| `NoteGraphServiceTests` | Wikilink (with aliases) and Markdown link extraction, link resolution, graph edges and degrees, folder hubs and clustering, valid 3D layout coordinates. |
| `LocalAIServicesTests` | AI model types: download state transitions, capture configurations, speaker labels, frame metadata, request modes. |
| `LanguageModelServiceTests` (+ `AssistantChatTests.swift`, which extends it) | Prompt wording per mode, empty-note and disabled errors (without loading the model), speaker labels, truncation marker. Chat: note attached only when new or changed, history replay of complete exchanges, failed turns, blank messages, context-usage labels and warning levels, custom instructions, skills sent from chat. |
| `SkillsTests` | Skill frontmatter and defaults, note placement (`{{note}}` or appended), empty notes, sort order, default skills and template; library seeding once per vault, restore keeps edits, unique new names, ignored files; the test host never seeds the user's vault. |
| `VaultAppFoldersTests` | Which attachment settings make an app folder, case-insensitive membership, sidebar split and order, graph excludes Skills and attachments. |
| `HubAdaptersTests` | Gemma 4's all-ones attention mask is dropped for text prompts (so chat turns reuse the KV cache) and kept for real masks and media; opt-in real-model check that a follow-up reuses the cache. |
| `LanguageModelBenchmarkTests` | Opt-in speed measurements (load, first token, prompt and generation tokens/s, prewarm); see [On-Device AI & Meetings](local-ai.md#testing). |
| `VisualCaptureServiceTests` | AppKit → ScreenCaptureKit coordinates (including a display above the main one), the disabled setting for both capture modes, picker configuration (one window, app or display; brain-md excluded) and full-resolution capture size. |
| `MeetingTranscriptionTests` | Sample-buffer conversion, level meter mapping, transcript line format, transcription language default, locale matching (`nl_BE`, `nl` → `nl_NL`, `en_BE` → `en_US`). |
| `SpeechRecognitionTests` | Engine choice (speech model, Gemma 4 E4B, Apple Speech; AI off or Intel), catalog integrity (unique ids, 40-character revisions, mlx-audio engine types), utterance cutting (pauses, live-word windows, max length, clicks, chunk-size independence), speaker timelines, "Me" / "Speaker N" / "Them" labels in note lines and minutes, per-engine settings. |
| `TranscriptWriterTests` | Transcript paragraphs: same speaker joins one timestamp, speaker changes, "Them" grouping, 30-second pauses, two-minute monologues, text typed after the transcript is kept, edits earlier in the note, out-of-order segments, minutes use the same paragraphs. |
| `TranscriptNoteTests` | Transcript lines stay in the note the recording started in: written to its file after a note switch (vault notes and files from Finder), back in the editor when you return to it. |
| `AIFeaturesTests` | The AI Features master switch: on by default, overrides on-device AI without forgetting it, keeps meetings on Apple Speech while off, stops a recording and unloads the model. |
| `ExternalFilesTests` | Markdown files from Finder: outside files open in the editor, vault files open as their note, saving writes back to the outside file, switching notes saves it first, Add to Vault copies edits and leaves the original, only Markdown opens, vault-relative paths. |
| `AutosaveTests` | Debounced auto-save: saves after the delay and not before, each edit restarts it, outside files save to themselves, a pending save doesn't fire for the next note, waits while suspended (meeting transcript) and saves when resumed, delay read from Settings with a 1 s default. |
| `MarkdownQuickLookTests` | Quick Look HTML: static rendering without scripts, network blocked by the content security policy, dark mode styles, Mermaid as code, local images attached and their alt-text fallback; regression for inline images in paragraphs, lists, tables and alerts. |
| `GemmaAudioTests` / `BrainGemma4AudioPortTests` | The ported Gemma 4 audio encoder: feature shapes, encoder output, weight mapping; opt-in real transcription. |
| `MLXSpeechIntegrationTests`, `AlternativeLanguageModelTests`, `CatalogConfigCheckTests` | Opt-in real speech models, Qwen3.5 and catalog network checks; see [On-Device AI & Meetings](local-ai.md#testing). |
| Opt-in real-model and speech tests | Run with `TEST_RUNNER_BRAINMD_MODEL_INTEGRATION=1` or `TEST_RUNNER_BRAINMD_SPEECH_INTEGRATION=1`; see [On-Device AI & Meetings](local-ai.md#testing). |

---

## Code Quality & Architecture Guidelines

1. **Strict Concurrency**:
   - All shared state must be protected by `@MainActor` or encapsulated within thread-safe actor/isolation boundaries.
   - Avoid nonisolated references to actor properties in `deinit`.
2. **Zero Runtime Dependencies**:
   - Do not introduce external package dependencies (via Swift Package Manager or CocoaPods) unless strictly necessary. `brain-md` relies on Apple's standard frameworks (`SwiftUI`, `AppKit`, `WebKit`, `Network`, `Foundation`).
   - **Exception: on-device AI.** Running models needs MLX, so the app pins `mlx-swift-lm` 3.32.3, `mlx-swift` 0.32.3, `mlx-audio-swift` 0.1.5 (speech models and Sortformer, MIT), `swift-huggingface` 0.13.0 and `swift-transformers` 1.3.4 to exact versions (`Package.resolved` is committed). Check new versions for advisories before bumping; see [On-Device AI & Meetings](local-ai.md#download-storage-and-memory) for the open yyjson advisory.
   - **Building MLX needs the Metal Toolchain:** `xcodebuild -downloadComponent MetalToolchain` (once per Xcode install).
3. **Defensive Path Operations**:
   - Never use raw file paths without passing them through `resolveSecurePath(relativePath:)`.
4. **AppKit Integration**:
   - When AppKit window bridges (`NSViewRepresentable`) are used (such as `SettingsWindowConfigurator`), always wrap UI mutations in `@MainActor` and dispatch to the main queue.
