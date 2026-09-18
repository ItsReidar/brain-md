//
//  EditorSplitView.swift
//  brain-md
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum ViewMode: String, CaseIterable, Identifiable {
    case split = "Split"
    case editor = "Editor"
    case preview = "Preview"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .editor: return "pencil"
        case .preview: return "eye"
        }
    }
}

public struct EditorSplitView: View {
    @ObservedObject var vault: VaultManager
    @State private var viewMode: ViewMode = .split
    
    // Bubble / Toast state
    @State private var showingBubble = false
    @State private var bubbleMessage = ""
    @State private var bubbleDismissTask: Task<Void, Never>? = nil
    
    public init(vault: VaultManager) {
        self.vault = vault
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let selected = vault.selectedItem {
                    // Top Editor Toolbar
                    editorHeader(item: selected)
                    
                    Divider()
                    
                    // Editor & Preview Content Area
                    GeometryReader { geo in
                        switch viewMode {
                        case .split:
                            HStack(spacing: 0) {
                                MarkdownEditorView(
                                    text: Binding(
                                        get: { vault.editorContent },
                                        set: {
                                            vault.editorContent = $0
                                            vault.hasUnsavedChanges = true
                                        }
                                    ),
                                    onSave: {
                                        vault.saveCurrentNote()
                                        showBubble(message: "Note saved")
                                    }
                                )
                                .frame(width: max(200, (geo.size.width - 1) / 2))
                                
                                Divider()
                                
                                MarkdownPreviewView(markdown: vault.editorContent, onTagSelected: { tag in
                                    vault.selectedTag = tag
                                })
                                    .frame(width: max(200, (geo.size.width - 1) / 2))
                            }
                        case .editor:
                            MarkdownEditorView(
                                text: Binding(
                                    get: { vault.editorContent },
                                    set: {
                                        vault.editorContent = $0
                                        vault.hasUnsavedChanges = true
                                    }
                                ),
                                onSave: {
                                    vault.saveCurrentNote()
                                    showBubble(message: "Note saved")
                                }
                            )
                        case .preview:
                            MarkdownPreviewView(markdown: vault.editorContent, onTagSelected: { tag in
                                vault.selectedTag = tag
                            })
                        }
                    }
                } else {
                    emptyStateView
                }
            }
            
            // Floating Bubble Notification at Bottom Middle
            if showingBubble {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 13, weight: .semibold))
                    Text(bubbleMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .padding(.bottom, 24)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity).combined(with: .move(edge: .bottom)),
                    removal: .scale(scale: 0.95).combined(with: .opacity)
                ))
                .zIndex(1000)
                .allowsHitTesting(false)
            }
        }
    }
    
    // MARK: - Editor Header
    
    private func editorHeader(item: NoteItem) -> some View {
        HStack(spacing: 12) {
            // Note Title & Unsaved Indicator
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundColor(.accentColor)
                Text(item.relativePath)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                if vault.hasUnsavedChanges {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                }
                
                if !item.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.tags.prefix(3), id: \.self) { tag in
                            Button(action: {
                                vault.selectedTag = tag
                            }) {
                                Text("#\(tag)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.primary.opacity(0.06))
                                    .cornerRadius(3)
                            }
                            .buttonStyle(.plain)
                            .help("Filter vault by #\(tag)")
                        }
                    }
                }
            }
            
            Spacer()
            
            // Note Stats (Words, Chars, Read Time)
            HStack(spacing: 10) {
                let words = countWords(vault.editorContent)
                let minutes = max(1, words / 200)
                
                Text("\(words) words")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("•")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text("\(minutes) min read")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            // View Mode Switcher
            Picker("View Mode", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            
            // Action Buttons in Top Right
            HStack(spacing: 4) {
                // Download File Button
                ToolbarIconButton(
                    icon: "square.and.arrow.down",
                    helpText: "Download File"
                ) {
                    downloadFile(item: item)
                }
                
                // Copy Markdown Button
                ToolbarIconButton(
                    icon: "doc.on.doc",
                    helpText: "Copy Markdown"
                ) {
                    copyMarkdownContent()
                }
            }
            // Hidden Save shortcut (⌘S)
            .background(
                Button("") {
                    vault.saveCurrentNote()
                    showBubble(message: "Note saved")
                }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    private func copyMarkdownContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vault.editorContent, forType: .string)
        showBubble(message: "File contents copied")
    }
    
    private func downloadFile(item: NoteItem) {
        // Save current modifications first
        vault.saveCurrentNote()
        
        let savePanel = NSSavePanel()
        savePanel.title = "Download Note"
        savePanel.message = "Choose destination to download this Markdown file"
        savePanel.prompt = "Download"
        
        var fileName = item.name
        if !fileName.hasSuffix(".md") && !fileName.hasSuffix(".markdown") {
            fileName += ".md"
        }
        savePanel.nameFieldStringValue = fileName
        savePanel.canCreateDirectories = true
        
        if let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = downloadsDir
        }
        
        let writeOperation: (URL) -> Void = { targetURL in
            do {
                try self.vault.editorContent.write(to: targetURL, atomically: true, encoding: .utf8)
                self.showBubble(message: "File downloaded")
            } catch {
                self.showBubble(message: "Download failed")
            }
        }
        
        if let window = NSApp.keyWindow {
            savePanel.beginSheetModal(for: window) { response in
                if response == .OK, let targetURL = savePanel.url {
                    writeOperation(targetURL)
                }
            }
        } else {
            if savePanel.runModal() == .OK, let targetURL = savePanel.url {
                writeOperation(targetURL)
            }
        }
    }
    
    private func showBubble(message: String) {
        bubbleDismissTask?.cancel()
        bubbleMessage = message
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            showingBubble = true
        }
        bubbleDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showingBubble = false
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundColor(.accentColor.opacity(0.8))
            Text("Welcome to Brain-md")
                .font(.title2.bold())
            Text("Select a note from the sidebar or create a new one to start writing.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("Create New Note") {
                vault.promptNewNote()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private func countWords(_ string: String) -> Int {
        let words = string.split { $0.isWhitespace || $0.isNewline }
        return words.count
    }
}

// MARK: - Toolbar Icon Button

private struct ToolbarIconButton: View {
    let icon: String
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered = $0 }
    }
}
