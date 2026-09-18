//
//  SidebarView.swift
//  brain-md
//

import SwiftUI
import AppKit

public struct SidebarView: View {
    @ObservedObject var vault: VaultManager
    @ObservedObject var httpServer = MCPHTTPServer.shared
    @Binding var showingMCPModal: Bool
    
    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: NoteItem?
    @State private var renameText = ""
    @State private var showingRenameAlert = false
    @State private var isHeaderDropTargeted = false
    @State private var isRootDropTargeted = false
    @State private var isTagsExpanded = true
    
    public init(vault: VaultManager, showingMCPModal: Binding<Bool>) {
        self.vault = vault
        self._showingMCPModal = showingMCPModal
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Vault Header with drop target to root
            vaultHeader
            
            Divider()
            
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search notes or content...", text: $vault.searchQuery)
                    .textFieldStyle(.plain)
                if !vault.searchQuery.isEmpty {
                    Button(action: { vault.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            
            // Active Tag Filter Chip
            if let activeTag = vault.selectedTag {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                    Text("#\(activeTag)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    let count = vault.allTags[activeTag] ?? 0
                    Text("(\(count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: {
                        vault.selectedTag = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear tag filter")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            
            Divider()
            
            // Files List or Search Results or Tag Filter
            if !vault.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResultsList
            } else if let selectedTag = vault.selectedTag {
                tagFilteredNotesList(tag: selectedTag)
            } else {
                fileTreeList
            }
            
            Divider()
            
            // Bottom Action Bar
            bottomBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                if !newFolderName.isEmpty {
                    try? vault.createFolder(relativePath: newFolderName)
                    newFolderName = ""
                }
            }
        }
        .alert("Rename Item", isPresented: $showingRenameAlert) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renameText = ""
                renamingItem = nil
            }
            Button("Rename") {
                if let item = renamingItem, !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try vault.renameItem(oldRelativePath: item.relativePath, newName: renameText)
                    } catch {
                        vault.logActivity(action: "Rename Failed", detail: error.localizedDescription, isError: true)
                    }
                    renameText = ""
                    renamingItem = nil
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var vaultHeader: some View {
        HStack(spacing: 8) {
            Button(action: chooseVaultFolder) {
                HStack(spacing: 6) {
                    Image(systemName: isHeaderDropTargeted ? "tray.and.arrow.down.fill" : "folder.fill.badge.gearshape")
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isHeaderDropTargeted ? "Move to Vault Root" : vault.vaultURL.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isHeaderDropTargeted ? .accentColor : .primary)
                            .lineLimit(1)
                        Text(isHeaderDropTargeted ? "Release to drop into root directory" : "Click to switch folder")
                            .font(.system(size: 9))
                            .foregroundColor(isHeaderDropTargeted ? .accentColor : .secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .dropDestination(for: String.self) { droppedItems, _ in
                guard let sourcePath = droppedItems.first else { return false }
                do {
                    try vault.moveItem(sourceRelativePath: sourcePath, toDirectoryRelativePath: "")
                    return true
                } catch {
                    return false
                }
            } isTargeted: { targeted in
                self.isHeaderDropTargeted = targeted
            }
            
            Spacer()
            
            // MCP Status Badge
            Button(action: { showingMCPModal = true }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(httpServer.isRunning ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text("MCP")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .help("MCP Server: \(httpServer.isRunning ? "Online on port \(httpServer.port)" : "Offline")")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHeaderDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHeaderDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }
    
    // MARK: - File Tree
    
    private var fileTreeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !vault.allTags.isEmpty {
                    tagsSection
                    Divider()
                        .padding(.vertical, 4)
                }
                
                ForEach(vault.rootItems) { item in
                    ItemRowView(
                        item: item,
                        selectedItem: vault.selectedItem,
                        onSelect: { selected in
                            vault.selectNote(selected)
                        },
                        onRename: { target in
                            renamingItem = target
                            renameText = target.displayName
                            showingRenameAlert = true
                        },
                        onDelete: { target in
                            try? vault.deleteFile(relativePath: target.relativePath)
                        },
                        onMove: { sourcePath, targetDirectory in
                            try? vault.moveItem(sourceRelativePath: sourcePath, toDirectoryRelativePath: targetDirectory)
                        }
                    )
                }
                
                // Vault Root drop zone at the bottom of the list for easy moving out of folders
                HStack(spacing: 6) {
                    Image(systemName: isRootDropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                        .font(.system(size: 11))
                    Text(isRootDropTargeted ? "Release to move to Vault Root" : "Vault Root (Drop here to move out of folders)")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(isRootDropTargeted ? .accentColor : .secondary.opacity(0.65))
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isRootDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isRootDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                )
                .dropDestination(for: String.self) { droppedItems, _ in
                    guard let sourcePath = droppedItems.first else { return false }
                    do {
                        try vault.moveItem(sourceRelativePath: sourcePath, toDirectoryRelativePath: "")
                        return true
                    } catch {
                        return false
                    }
                } isTargeted: { targeted in
                    self.isRootDropTargeted = targeted
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let sourcePath = droppedItems.first else { return false }
            do {
                try vault.moveItem(sourceRelativePath: sourcePath, toDirectoryRelativePath: "")
                return true
            } catch {
                return false
            }
        }
    }
    
    // MARK: - Search Results
    
    private var searchResultsList: some View {
        let results = vault.searchNotes(query: vault.searchQuery)
        return Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No matching notes")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { res in
                    Button(action: {
                        if let item = findItem(path: res.relativePath, in: vault.rootItems) {
                            vault.selectNote(item)
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accentColor)
                                Text(res.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                            }
                            Text(res.relativePath)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            if !res.snippet.isEmpty {
                                Text(res.snippet)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }
    
    private func findItem(path: String, in items: [NoteItem]) -> NoteItem? {
        for item in items {
            if item.relativePath == path { return item }
            if let children = item.children, let found = findItem(path: path, in: children) {
                return found
            }
        }
        return nil
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack {
            Button(action: {
                vault.promptNewNote()
            }) {
                Label("New Note", systemImage: "square.and.pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Button(action: {
                newFolderName = ""
                showingNewFolderAlert = true
            }) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("New Folder")
            
            Button(action: { vault.refreshFiles() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Reload Vault")
            
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Tags Section & Filter View
    
    private var tagsSection: some View {
        DisclosureGroup(
            isExpanded: $isTagsExpanded,
            content: {
                VStack(alignment: .leading, spacing: 2) {
                    let sortedTags = vault.allTags.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                    ForEach(sortedTags, id: \.key) { tag, count in
                        Button(action: {
                            if vault.selectedTag == tag {
                                vault.selectedTag = nil
                            } else {
                                vault.selectedTag = tag
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(vault.selectedTag == tag ? .accentColor : .secondary)
                                Text("#\(tag)")
                                    .font(.system(size: 11, weight: vault.selectedTag == tag ? .semibold : .regular))
                                    .foregroundColor(vault.selectedTag == tag ? .accentColor : .primary)
                                Spacer()
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(Capsule())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(vault.selectedTag == tag ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 6)
                .padding(.top, 2)
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("Tags")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(vault.allTags.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
        )
    }
    
    private func tagFilteredNotesList(tag: String) -> some View {
        let matchingNotes = vault.getNotes(taggedWith: tag)
        return ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                if matchingNotes.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "tag.slash")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("No notes with tag #\(tag)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(matchingNotes) { note in
                        Button(action: {
                            vault.selectNote(note)
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundColor(vault.selectedItem?.id == note.id ? .accentColor : .secondary)
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.displayName)
                                        .font(.system(size: 12.5, weight: vault.selectedItem?.id == note.id ? .semibold : .regular))
                                        .foregroundColor(vault.selectedItem?.id == note.id ? .accentColor : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(note.relativePath)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(vault.selectedItem?.id == note.id ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
    
    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Vault Folder"
        panel.directoryURL = vault.vaultURL
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            vault.setVaultURL(selectedURL)
        }
    }
}

// MARK: - Recursive Item Row

private struct ItemRowView: View {
    let item: NoteItem
    let selectedItem: NoteItem?
    let onSelect: (NoteItem) -> Void
    let onRename: (NoteItem) -> Void
    let onDelete: (NoteItem) -> Void
    let onMove: (String, String) -> Void
    
    @State private var isExpanded = true
    @State private var isDropTargeted = false
    
    var body: some View {
        if item.isDirectory {
            DisclosureGroup(
                isExpanded: $isExpanded,
                content: {
                    if let children = item.children {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(children) { child in
                                ItemRowView(
                                    item: child,
                                    selectedItem: selectedItem,
                                    onSelect: onSelect,
                                    onRename: onRename,
                                    onDelete: onDelete,
                                    onMove: onMove
                                )
                            }
                        }
                        .padding(.leading, 14)
                    }
                },
                label: {
                    HStack(spacing: 6) {
                        Image(systemName: isDropTargeted ? "folder.badge.plus" : item.iconName)
                            .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                            .font(.system(size: 13))
                        Text(item.displayName)
                            .foregroundColor(isDropTargeted ? .accentColor : .primary)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .draggable(item.relativePath) {
                        dragPreview(icon: item.iconName, text: item.displayName)
                    }
                    .dropDestination(for: String.self) { droppedItems, _ in
                        guard let sourcePath = droppedItems.first, sourcePath != item.relativePath else { return false }
                        if item.relativePath.hasPrefix(sourcePath + "/") { return false }
                        onMove(sourcePath, item.relativePath)
                        isExpanded = true
                        return true
                    } isTargeted: { targeted in
                        self.isDropTargeted = targeted
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contextMenu {
                        Button("Rename Folder") { onRename(item) }
                        Button("Delete Folder", role: .destructive) { onDelete(item) }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                    }
                }
            )
        } else {
            HStack(spacing: 6) {
                Image(systemName: item.iconName)
                    .foregroundColor(selectedItem?.id == item.id ? .accentColor : .secondary)
                    .font(.system(size: 13))
                Text(item.displayName)
                    .foregroundColor(selectedItem?.id == item.id ? .accentColor : .primary)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(item)
            }
            .draggable(item.relativePath) {
                dragPreview(icon: item.iconName, text: item.displayName)
            }
            .dropDestination(for: String.self) { droppedItems, _ in
                guard let sourcePath = droppedItems.first, sourcePath != item.relativePath else { return false }
                let parentDir = (item.relativePath as NSString).deletingLastPathComponent
                onMove(sourcePath, parentDir)
                return true
            } isTargeted: { targeted in
                self.isDropTargeted = targeted
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : (selectedItem?.id == item.id ? Color.accentColor.opacity(0.15) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contextMenu {
                Button("Rename Note") { onRename(item) }
                Button("Delete Note", role: .destructive) { onDelete(item) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.relativePath, forType: .string)
                }
            }
        }
    }
    
    @ViewBuilder
    private func dragPreview(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
