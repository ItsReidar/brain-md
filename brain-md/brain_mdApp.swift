//
//  brain_mdApp.swift
//  brain-md
//

import SwiftUI

@main
struct brain_mdApp: App {
    /// Receives Markdown files opened from Finder.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // mlx-audio-swift loads some speech models through the default Hugging Face cache; point it at
        // brain-md's models folder before anything loads.
        ModelStore.configureDefaultCache()
        let args = CommandLine.arguments
        
        // Custom vault path argument (e.g. brain-md --vault /path/to/notes)
        if let idx = args.firstIndex(of: "--vault"), idx + 1 < args.count {
            let path = args[idx + 1]
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            VaultManager.shared.setVaultURL(url)
        }
        
        // Headless Stdio MCP Server mode
        if args.contains("--stdio") || args.contains("--mcp") {
            Task {
                await MCPStdioServer.shared.run()
                exit(0)
            }
            dispatchMain()
        }
        
        // Default GUI launch: start HTTP/SSE MCP server asynchronously to keep launch instantaneous
        DispatchQueue.global(qos: .userInitiated).async {
            MCPHTTPServer.shared.start(preferredPort: 8765)
        }
    }

    var body: some Scene {
        // Each window is a native tab with its own note; the value is the note it opens with.
        WindowGroup(for: NoteWindowRequest.self) { $request in
            ContentView(request: request)
        }
        // Brain.md reopens the tabs itself (VaultManager.restoreTabs), per vault.
        .restorationBehavior(.disabled)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    VaultManager.shared.promptNewNote()
                }
                .keyboardShortcut("n", modifiers: .command)

                NewTabButton()
                
                Button("Quick Open Note...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenQuickSwitcher"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button("Save Note") {
                    VaultManager.shared.saveCurrentNote()
                }
                .keyboardShortcut("s", modifiers: .command)

                Button("Move to Trash") {
                    VaultManager.shared.commandDelete(firstResponder: NSApp.keyWindow?.firstResponder)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                
                Divider()
                
                Button("Export Preview as PDF...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ExportCurrentNoteAsPDF"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            
            CommandMenu("View") {
                Button("Split View") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetViewModeSplit"), object: nil)
                }
                .keyboardShortcut("1", modifiers: [.command, .control])
                
                Button("Editor Only") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetViewModeEditor"), object: nil)
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                
                Button("Preview Only") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetViewModePreview"), object: nil)
                }
                .keyboardShortcut("3", modifiers: [.command, .control])

                OpenAssistantChatButton()
            }
            
            CommandMenu("Format") {
                Menu("Headings") {
                    Button("Heading 1") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 1))
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    
                    Button("Heading 2") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 2))
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    
                    Button("Heading 3") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 3))
                    }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                    
                    Button("Heading 4") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 4))
                    }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                    
                    Button("Heading 5") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 5))
                    }
                    .keyboardShortcut("5", modifiers: [.command, .option])
                    
                    Button("Heading 6") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.heading(level: 6))
                    }
                    .keyboardShortcut("6", modifiers: [.command, .option])
                }
                
                Divider()
                
                Button("Paragraph") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.paragraph)
                }
                
                Button("Line Break") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.lineBreak)
                }
                
                Divider()
                
                Menu("Emphasis") {
                    Button("Bold") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.bold)
                    }
                    .keyboardShortcut("b", modifiers: .command)
                    
                    Button("Italic") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.italic)
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    
                    Button("Bold & Italic") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.boldItalic)
                    }
                    
                    Button("Strikethrough") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.strikethrough)
                    }
                }
                
                Button("Blockquote") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.blockquote)
                }
                
                Menu("Lists") {
                    Button("Bullet List") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.unorderedList)
                    }
                    Button("Numbered List") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.orderedList)
                    }
                    Button("Task List") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.taskList)
                    }
                }
                
                Menu("Code") {
                    Button("Inline Code") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.inlineCode)
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    
                    Button("Code Block") {
                        NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.codeBlock)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                }
                
                Divider()
                
                Button("Horizontal Rule") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.horizontalRule)
                }
                
                Button("Link") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.link)
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Button("Image") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.image)
                }
                
                Divider()
                
                Button("Escaping Characters") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.escapingCharacters)
                }
                
                Button("HTML Block") {
                    NotificationCenter.default.post(name: MarkdownFormatService.notificationName, object: MarkdownFormatElement.html)
                }
            }
        }
        
        Window("AI Chat", id: AssistantChatView.windowID) {
            AssistantChatView(chat: .shared, vault: .shared)
        }
        .defaultSize(width: 520, height: 640)
        // A restored chat window would stop SwiftUI from opening the editor window at launch.
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(vault: VaultManager.shared)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

/// View › AI Chat (⇧⌘J), hidden with the AI Features switch. A view so it can read `openWindow`.
private struct OpenAssistantChatButton: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AIFeatures.key) private var showsAIFeatures = true

    var body: some View {
        if showsAIFeatures {
            Divider()
            Button("AI Chat") { openWindow(id: AssistantChatView.windowID) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}

/// File › New Tab (⌘T): an empty note window, opened as a tab. A view so it can read `openWindow`.
private struct NewTabButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Tab") { openWindow(value: NoteWindowRequest(path: nil)) }
            .keyboardShortcut("t", modifiers: .command)
    }
}
