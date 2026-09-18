//
//  ContentView.swift
//  brain-md
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vault = VaultManager.shared
    @StateObject private var httpServer = MCPHTTPServer.shared
    @StateObject private var themeManager = ThemeManager.shared
    @State private var showingMCPModal = false
    @State private var newNoteTitle = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(vault: vault, showingMCPModal: $showingMCPModal)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            EditorSplitView(vault: vault)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingMCPModal) {
            MCPServerModalView()
        }
        .alert("New Note", isPresented: $vault.showingNewNotePrompt) {
            TextField("Note title (e.g. Ideas.md)", text: $newNoteTitle)
            Button("Cancel", role: .cancel) {
                newNoteTitle = ""
            }
            Button("Create") {
                let trimmed = newNoteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let nameToUse = trimmed.isEmpty ? vault.newNotePromptDefaultName : trimmed
                if !nameToUse.isEmpty {
                    _ = try? vault.createNote(named: nameToUse)
                }
                newNoteTitle = ""
            }
        }
        .onChange(of: vault.showingNewNotePrompt) { _, isPresented in
            if isPresented {
                newNoteTitle = vault.newNotePromptDefaultName
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { showingMCPModal = true }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(httpServer.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(httpServer.isRunning ? "MCP :\(String(httpServer.port))" : "MCP Offline")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .help("Open MCP Server Inspector & Agent Config")
                
                Button(action: {
                    vault.promptNewNote()
                }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onAppear {
            if !httpServer.isRunning {
                httpServer.start(preferredPort: 8765)
            }
        }
        .preferredColorScheme(themeManager.effectiveColorScheme)
        .id(themeManager.refreshTrigger)
    }
}

#Preview {
    ContentView()
}
