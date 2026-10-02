//
//  QuickSwitcherModalView.swift
//  brain-md
//

import SwiftUI
import AppKit

public struct QuickSwitcherModalView: View {
    @ObservedObject var vault: VaultManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool
    
    public init(vault: VaultManager) {
        self.vault = vault
    }
    
    private var allNotePaths: [String] {
        vault.getAllNotePaths()
    }
    
    private var filteredNotes: [QuickSwitcherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let items: [QuickSwitcherItem] = allNotePaths.map { path in
            let fileName = (path as NSString).lastPathComponent
            let title = fileName.lowercased().hasSuffix(".md") ? String(fileName.dropLast(3)) : fileName
            let folder = (path as NSString).deletingLastPathComponent
            return QuickSwitcherItem(
                relativePath: path,
                title: title,
                folder: folder.isEmpty ? "Root" : folder
            )
        }
        
        if trimmed.isEmpty {
            return items
        }
        
        return items.filter { item in
            item.title.lowercased().contains(trimmed) || item.relativePath.lowercased().contains(trimmed)
        }.sorted { a, b in
            // Exact prefix or title match prioritizes first
            let aTitleMatch = a.title.lowercased().hasPrefix(trimmed)
            let bTitleMatch = b.title.lowercased().hasPrefix(trimmed)
            if aTitleMatch != bTitleMatch {
                return aTitleMatch && !bTitleMatch
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                
                TextField("Quick Open Note... (type to search)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
                    .onSubmit {
                        openSelected()
                    }
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                    }
                
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("\(filteredNotes.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            
            Divider()
            
            // Notes Results List
            if filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("No matching notes found")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredNotes.enumerated()), id: \.element.relativePath) { idx, item in
                                QuickSwitcherRow(
                                    item: item,
                                    isSelected: idx == selectedIndex,
                                    onSelect: {
                                        selectAndOpen(item)
                                    }
                                )
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
            
            Divider()
            
            // Footer with keyboard tips
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("↑/↓")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(3)
                    Text("Navigate")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Text("Return")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(3)
                    Text("Open")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Text("Esc")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(3)
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 380)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("QuickSwitcherDown"))) { _ in
            if selectedIndex < filteredNotes.count - 1 {
                selectedIndex += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("QuickSwitcherUp"))) { _ in
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
    }
    
    private func selectAndOpen(_ item: QuickSwitcherItem) {
        vault.selectNote(byRelativePath: item.relativePath)
        dismiss()
    }
    
    private func openSelected() {
        guard !filteredNotes.isEmpty, selectedIndex >= 0, selectedIndex < filteredNotes.count else { return }
        let item = filteredNotes[selectedIndex]
        selectAndOpen(item)
    }
}

// MARK: - Row View

public struct QuickSwitcherItem: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let title: String
    public let folder: String
}

private struct QuickSwitcherRow: View {
    let item: QuickSwitcherItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                    
                    Text(item.relativePath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if item.folder != "Root" {
                    Text(item.folder)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
