//
//  ContentView.swift
//  brain-md
//

import SwiftUI

struct ContentView: View {
    @StateObject private var vault = VaultManager.shared
    /// This window's note; each window (and so each native tab) has its own.
    @StateObject private var session: EditorSession
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appearsActive) private var appearsActive
    @StateObject private var httpServer = MCPHTTPServer.shared
    @StateObject private var themeManager = ThemeManager.shared
    @State private var showingMCPModal = false
    @State private var showingGraphModal = false
    @State private var showingQuickSwitcher = false
    @State private var newNoteTitle = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(request: NoteWindowRequest? = nil) {
        _session = StateObject(wrappedValue: VaultManager.shared.claimSession(loading: request?.path))
    }

    private var isFrontmost: Bool { vault.activeSession === session }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(vault: vault, session: session, showingMCPModal: $showingMCPModal)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            EditorSplitView(vault: vault, session: session)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingMCPModal) {
            MCPServerModalView()
        }
        .sheet(isPresented: $showingGraphModal) {
            BrainGraphModalView(vault: vault)
        }
        .sheet(isPresented: $showingQuickSwitcher) {
            QuickSwitcherModalView(vault: vault)
        }
        .alert("New Note", isPresented: Binding(
            get: { vault.showingNewNotePrompt && isFrontmost },
            set: { vault.showingNewNotePrompt = $0 }
        )) {
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
                
                Button(action: { showingGraphModal = true }) {
                    Image(systemName: "brain.head.profile")
                }
                .help("3D Brain Graph (⌥⌘G)")
                .keyboardShortcut("g", modifiers: [.option, .command])
                
                Button(action: { showingQuickSwitcher = true }) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Quick Open Note... (⌘O)")
                .keyboardShortcut("o", modifiers: .command)
                
                Button(action: {
                    vault.promptNewNote()
                }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenQuickSwitcher"))) { _ in
            if isFrontmost { showingQuickSwitcher = true }
        }
        // The tab is named after its note.
        .navigationTitle(session.selectedItem?.displayName ?? "Brain.md")
        .background(WindowReader { vault.attach(session, to: $0) })
        .onChange(of: appearsActive, initial: true) { _, active in
            if active { vault.activate(session) }
        }
        .onAppear {
            vault.openWindowHandler = { openWindow(value: $0) }
            vault.openPendingTabs()
            if !httpServer.isRunning {
                httpServer.start(preferredPort: 8765)
            }
        }
        .preferredColorScheme(themeManager.effectiveColorScheme)
        .id(themeManager.refreshTrigger)
    }
}

/// Hands over the view's window as soon as it's in one, before the window is first shown.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
