//
//  brain_mdApp.swift
//  brain-md
//

import SwiftUI

@main
struct brain_mdApp: App {
    init() {
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
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    VaultManager.shared.promptNewNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Button("Save Note") {
                    VaultManager.shared.saveCurrentNote()
                }
                .keyboardShortcut("s", modifiers: .command)
                
                Divider()
                
                Button("Export Preview as PDF...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ExportCurrentNoteAsPDF"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
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
        
        Settings {
            SettingsView(vault: VaultManager.shared)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
