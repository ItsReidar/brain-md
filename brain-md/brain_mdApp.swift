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
            }
        }
        
        Settings {
            SettingsView(vault: VaultManager.shared)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}
