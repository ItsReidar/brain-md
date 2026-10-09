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
    @AppStorage("editor_sync_scroll") private var syncPreviewScroll: Bool = true
    @AppStorage("editor_split_ratio") private var splitRatio: Double = 0.5
    @ObservedObject private var scrollSync = ScrollSyncCoordinator.shared
    
    @State private var isDraggingSplit = false
    
    // Bubble / Toast state
    @State private var showingBubble = false
    @State private var bubbleMessage = ""
    @State private var bubbleDismissTask: Task<Void, Never>? = nil
    @State private var isRecordingMeeting = false
    @ObservedObject private var modelManager = LocalModelManager.shared
    @AppStorage(LocalModelManager.enabledDefaultsKey) private var isAIEnabled = false
    @State private var aiRequest: AIResultRequest?
    @Environment(\.openSettings) private var openSettings
    
    public init(vault: VaultManager) {
        self.vault = vault
    }
    
    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if let selected = vault.selectedItem {
                    if selected.isAttachment {
                        AttachmentDetailView(
                            item: selected,
                            vault: vault,
                            onShowBubble: { showBubble(message: $0) }
                        )
                    } else {
                        // Top Editor Toolbar
                        editorHeader(item: selected)
                        
                        Divider()
                        
                        // Editor & Preview Content Area
                    GeometryReader { geo in
                        switch viewMode {
                        case .split:
                            let totalWidth = geo.size.width
                            let dividerWidth: CGFloat = 8
                            let availableWidth = max(0, totalWidth - dividerWidth)
                            let clampedRatio = SplitDivider.clampRatio(splitRatio)
                            let editorWidth = max(200, availableWidth * CGFloat(clampedRatio))
                            let previewWidth = max(200, availableWidth - editorWidth)
                            
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
                                    },
                                    onImageDroppedOrPasted: { data, filename in
                                        do {
                                            let result = try vault.saveAttachment(
                                                data: data,
                                                suggestedFileName: filename,
                                                noteURL: vault.selectedItem?.url
                                            )
                                            showBubble(message: "Image added")
                                            return result.markdownReference
                                        } catch {
                                            showBubble(message: "Failed to save image: \(error.localizedDescription)")
                                            return nil
                                        }
                                    }
                                )
                                .frame(width: editorWidth)
                                
                                SplitDivider(
                                    isDragging: $isDraggingSplit,
                                    onDrag: { delta in
                                        let currentPx = availableWidth * CGFloat(clampedRatio)
                                        let newPx = currentPx + delta
                                        let newRatio = Double(newPx / max(1, availableWidth))
                                        splitRatio = SplitDivider.clampRatio(newRatio)
                                    },
                                    onDoubleClick: {
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                            splitRatio = 0.5
                                        }
                                    }
                                )
                                
                                MarkdownPreviewView(
                                    markdown: vault.editorContent,
                                    noteURL: vault.selectedItem?.url,
                                    vaultURL: vault.vaultURL,
                                    onTagSelected: { tag in
                                        vault.selectedTag = tag
                                    }
                                )
                                .frame(width: previewWidth)
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
                                },
                                onImageDroppedOrPasted: { data, filename in
                                    do {
                                        let result = try vault.saveAttachment(
                                            data: data,
                                            suggestedFileName: filename,
                                            noteURL: vault.selectedItem?.url
                                        )
                                        showBubble(message: "Image added")
                                        return result.markdownReference
                                    } catch {
                                        showBubble(message: "Failed to save image: \(error.localizedDescription)")
                                        return nil
                                    }
                                }
                            )
                        case .preview:
                            MarkdownPreviewView(
                                markdown: vault.editorContent,
                                noteURL: vault.selectedItem?.url,
                                vaultURL: vault.vaultURL,
                                onTagSelected: { tag in
                                    vault.selectedTag = tag
                                }
                            )
                        }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ExportCurrentNoteAsPDF"))) { _ in
            if let item = vault.selectedItem, !item.isDirectory {
                exportPreviewAsPDF(item: item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetViewModeSplit"))) { _ in
            viewMode = .split
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetViewModeEditor"))) { _ in
            viewMode = .editor
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SetViewModePreview"))) { _ in
            viewMode = .preview
        }
        .onAppear {
            scrollSync.isSyncEnabled = syncPreviewScroll
        }
        .sheet(item: $aiRequest) { request in
            AIResultSheet(
                request: request,
                onInsert: { result in
                    vault.editorContent += "\n\n" + result + "\n"
                    vault.hasUnsavedChanges = true
                    showBubble(message: "Inserted below")
                },
                onReplace: { result in
                    vault.editorContent = result + "\n"
                    vault.hasUnsavedChanges = true
                    showBubble(message: "Note replaced")
                }
            )
        }
        .onChange(of: syncPreviewScroll) { _, newValue in
            scrollSync.isSyncEnabled = newValue
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
            
            // Format & Heading Toolbar Items
            HStack(spacing: 6) {
                // Standalone Headings Toolbar Item
                Menu {
                    Button("Heading 1 (#)") { applyMarkdownFormat(.heading(level: 1)) }
                    Button("Heading 2 (##)") { applyMarkdownFormat(.heading(level: 2)) }
                    Button("Heading 3 (###)") { applyMarkdownFormat(.heading(level: 3)) }
                    Button("Heading 4 (####)") { applyMarkdownFormat(.heading(level: 4)) }
                    Button("Heading 5 (#####)") { applyMarkdownFormat(.heading(level: 5)) }
                    Button("Heading 6 (######)") { applyMarkdownFormat(.heading(level: 6)) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "number")
                            .font(.system(size: 11, weight: .medium))
                        Text("Headings")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .help("Insert Headings (# - ######)")
                
                // Format Section Toolbar Item
                Menu {
                    Button("Paragraph") { applyMarkdownFormat(.paragraph) }
                    Button("Line Break") { applyMarkdownFormat(.lineBreak) }
                    
                    Divider()
                    
                    Menu("Emphasis") {
                        Button("Bold (**text**)") { applyMarkdownFormat(.bold) }
                        Button("Italic (*text*)") { applyMarkdownFormat(.italic) }
                        Button("Bold & Italic (***text***)") { applyMarkdownFormat(.boldItalic) }
                        Button("Strikethrough (~~text~~)") { applyMarkdownFormat(.strikethrough) }
                    }
                    
                    Button("Blockquote (> quote)") { applyMarkdownFormat(.blockquote) }
                    
                    Menu("Lists") {
                        Button("Bullet List (- item)") { applyMarkdownFormat(.unorderedList) }
                        Button("Numbered List (1. item)") { applyMarkdownFormat(.orderedList) }
                        Button("Task List (- [ ] task)") { applyMarkdownFormat(.taskList) }
                    }
                    
                    Menu("Code") {
                        Button("Inline Code (`code`)") { applyMarkdownFormat(.inlineCode) }
                        Button("Code Block (```)") { applyMarkdownFormat(.codeBlock) }
                    }
                    
                    Divider()
                    
                    Button("Horizontal Rule (---)") { applyMarkdownFormat(.horizontalRule) }
                    Button("Link ([title](url))") { applyMarkdownFormat(.link) }
                    Button("Image (![alt](url))") { applyMarkdownFormat(.image) }
                    
                    Divider()
                    
                    Button("Escaping Characters (\\*)") { applyMarkdownFormat(.escapingCharacters) }
                    Button("HTML (<div>...</div>)") { applyMarkdownFormat(.html) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "textformat")
                            .font(.system(size: 11, weight: .medium))
                        Text("Format")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .help("Markdown Formatting Elements")
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
            
            // Sync Scroll Toggle (Active in Split View)
            if viewMode == .split {
                Button(action: {
                    syncPreviewScroll.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: syncPreviewScroll ? "link" : "link.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("Sync Scroll")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(syncPreviewScroll ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                    .foregroundColor(syncPreviewScroll ? .accentColor : .secondary)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help(syncPreviewScroll ? "Disable Synchronized Scrolling" : "Enable Synchronized Scrolling")
            }
            
            // Action Buttons in Top Right
            HStack(spacing: 4) {
                // Model download progress (started from Settings)
                if modelManager.state.status == .downloading {
                    HStack(spacing: 6) {
                        ProgressView(value: modelManager.state.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 70)
                        Text("\(Int(modelManager.state.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(5)
                    .help("Downloading Gemma 4 for on-device AI")
                }

                // Local AI Meeting Transcription & Screen Capture
                ToolbarIconButton(
                    icon: isRecordingMeeting ? "record.circle.fill" : "waveform.and.mic",
                    helpText: isRecordingMeeting ? "Stop Meeting Audio Capture" : "Capture Meeting Audio & Screen Diagrams"
                ) {
                    toggleMeetingRecording()
                }
                .foregroundColor(isRecordingMeeting ? .red : (modelManager.state.status == .ready ? .primary : .secondary.opacity(0.6)))

                // On-device AI actions (results open in a review sheet)
                Menu {
                    if isAIAvailable {
                        Button("Summarize Note") { runAI(.summarizeMeeting, title: "Summary") }
                        Button("Extract Action Items") { runAI(.extractActionItems, title: "Action Items") }
                        Button("Polish & Rewrite") { runAI(.rewrite, title: "Polished Note") }
                    } else {
                        Button("Set Up On-Device AI…") { openSettings() }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isAIAvailable ? .purple : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(isAIAvailable ? Color.purple.opacity(0.1) : Color.primary.opacity(0.05))
                        .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .help(isAIAvailable ? "On-device AI (Gemma 4)" : aiUnavailableReason)

                // Export as PDF Button
                ToolbarIconButton(
                    icon: "arrow.down.doc",
                    helpText: "Export Preview as PDF (⌘P)"
                ) {
                    exportPreviewAsPDF(item: item)
                }
                
                // Download File Button
                ToolbarIconButton(
                    icon: "square.and.arrow.down",
                    helpText: "Download Markdown File"
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
            // Hidden Save shortcut (⌘S) & Export PDF shortcut (⌘P)
            .background(
                Group {
                    Button("") {
                        vault.saveCurrentNote()
                        showBubble(message: "Note saved")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    
                    Button("") {
                        exportPreviewAsPDF(item: item)
                    }
                    .keyboardShortcut("p", modifiers: .command)
                }
                .opacity(0)
                .frame(width: 0, height: 0)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Actions
    
    private func applyMarkdownFormat(_ element: MarkdownFormatElement) {
        if viewMode == .preview {
            viewMode = .split
        }
        NotificationCenter.default.post(
            name: MarkdownFormatService.notificationName,
            object: element
        )
    }
    
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
    
    private func exportPreviewAsPDF(item: NoteItem) {
        vault.saveCurrentNote()
        
        let savePanel = NSSavePanel()
        savePanel.title = "Export Preview as PDF"
        savePanel.message = "Choose destination to save the rendered PDF"
        savePanel.prompt = "Export"
        savePanel.allowedContentTypes = [.pdf]
        
        var baseName = item.name
        if baseName.hasSuffix(".md") {
            baseName = String(baseName.dropLast(3))
        } else if baseName.hasSuffix(".markdown") {
            baseName = String(baseName.dropLast(9))
        }
        savePanel.nameFieldStringValue = "\(baseName).pdf"
        savePanel.canCreateDirectories = true
        
        if let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = downloadsDir
        }
        
        let exportOperation: (URL) -> Void = { targetURL in
            Task { @MainActor in
                do {
                    try await PDFExportService.shared.exportPDF(
                        markdown: self.vault.editorContent,
                        theme: ThemeManager.shared.currentTheme,
                        to: targetURL,
                        noteURL: self.vault.selectedItem?.url,
                        vaultURL: self.vault.vaultURL
                    )
                    self.showBubble(message: "PDF exported successfully")
                } catch {
                    self.showBubble(message: "PDF export failed: \(error.localizedDescription)")
                }
            }
        }
        
        if let window = NSApp.keyWindow {
            savePanel.beginSheetModal(for: window) { response in
                if response == .OK, let targetURL = savePanel.url {
                    exportOperation(targetURL)
                }
            }
        } else {
            if savePanel.runModal() == .OK, let targetURL = savePanel.url {
                exportOperation(targetURL)
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

    private func toggleMeetingRecording() {
        if isRecordingMeeting {
            isRecordingMeeting = false
            AudioCaptureService.shared.stopCapture()
            showBubble(message: "Meeting transcription stopped")
            vault.editorContent += "\n\n---\n### 📝 Meeting Minutes & Summary\n- Call and voice transcription concluded.\n"
            vault.hasUnsavedChanges = true
        } else {
            guard modelManager.state.status == .ready else {
                modelManager.startDownload()
                showBubble(message: "Downloading Gemma 4 E4B model first...")
                return
            }
            isRecordingMeeting = true
            showBubble(message: "Recording started. Listening to audio...")
            vault.editorContent += "\n\n## 🎙️ Live Meeting Transcript (\(Date().formatted(date: .omitted, time: .shortened)))\n"
            vault.hasUnsavedChanges = true
            AudioCaptureService.shared.startCapture { segment in
                vault.editorContent += "\n> \(segment.text)"
                vault.hasUnsavedChanges = true
            }
        }
    }

    private var isAIAvailable: Bool {
        isAIEnabled && modelManager.state.status == .ready
    }

    private var aiUnavailableReason: String {
        guard isAIEnabled else { return "Turn on on-device AI in Settings" }
        switch modelManager.state.status {
        case .downloading: return "Gemma 4 is still downloading (\(Int(modelManager.state.progress * 100))%)"
        case .error: return "The Gemma 4 download failed. Retry it in Settings"
        case .notDownloaded, .ready: return "Gemma 4 isn't downloaded yet. Open Settings to download it"
        }
    }

    private func runAI(_ mode: RewriteRequest.Mode, title: String) {
        let request = RewriteRequest(mode: mode, sourceText: vault.editorContent)
        aiRequest = AIResultRequest(title: title) { GemmaService.shared.stream(request) }
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

// MARK: - Interactive Draggable Split Divider

public struct SplitDivider: View {
    @Binding var isDragging: Bool
    var onDrag: (CGFloat) -> Void
    var onDoubleClick: () -> Void
    
    @State private var isHovered = false
    
    public init(
        isDragging: Binding<Bool>,
        onDrag: @escaping (CGFloat) -> Void,
        onDoubleClick: @escaping () -> Void
    ) {
        self._isDragging = isDragging
        self.onDrag = onDrag
        self.onDoubleClick = onDoubleClick
    }
    
    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
            
            // Visual drag handle pill
            Capsule()
                .fill(isDragging ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.7) : Color.clear))
                .frame(width: 3, height: 28)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    onDrag(value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    onDoubleClick()
                }
        )
        .help("Drag to resize editor & preview, double-click to center (50/50)")
    }
    
    public static func clampRatio(_ ratio: Double, minRatio: Double = 0.20, maxRatio: Double = 0.80) -> Double {
        min(max(ratio, minRatio), maxRatio)
    }
    
    public static func calculateWidths(totalWidth: CGFloat, dividerWidth: CGFloat = 8, ratio: Double, minWidth: CGFloat = 200) -> (editorWidth: CGFloat, previewWidth: CGFloat) {
        let available = max(0, totalWidth - dividerWidth)
        let clamped = clampRatio(ratio)
        let edW = max(minWidth, available * CGFloat(clamped))
        let prW = max(minWidth, available - edW)
        return (edW, prW)
    }
}

// MARK: - Attachment Detail View

public struct AttachmentDetailView: View {
    let item: NoteItem
    @ObservedObject var vault: VaultManager
    let onShowBubble: (String) -> Void
    
    @State private var imageSize: CGSize? = nil
    
    public init(item: NoteItem, vault: VaultManager, onShowBubble: @escaping (String) -> Void) {
        self.item = item
        self.vault = vault
        self.onShowBubble = onShowBubble
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            attachmentHeader
            Divider()
            if item.isImage {
                imageCanvas
            } else {
                genericFileCanvas
            }
        }
    }
    
    private var attachmentHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .foregroundColor(.accentColor)
                    .font(.system(size: 14))
                
                Text(item.relativePath)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                
                Text(item.url.pathExtension.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
                
                if !item.formattedSize.isEmpty {
                    Text(item.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                if let size = imageSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) px")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: {
                    let ref = item.isImage ? "![\(item.displayName)](\(item.relativePath))" : "[\(item.displayName)](\(item.relativePath))"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ref, forType: .string)
                    onShowBubble("Markdown link copied")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                        Text("Copy Link")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy Markdown reference syntax to clipboard")
                
                if item.isImage, let nsImage = NSImage(contentsOf: item.url) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([nsImage])
                        onShowBubble("Image copied to clipboard")
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Image")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy image data to clipboard")
                }
                
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal file in Finder")
                
                Button(action: {
                    NSWorkspace.shared.open(item.url)
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open in default system application")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var imageCanvas: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    if let nsImage = NSImage(contentsOf: item.url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: max(geo.size.width - 48, 100), maxHeight: max(geo.size.height - 48, 100))
                            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                            .padding(24)
                            .onAppear {
                                self.imageSize = nsImage.size
                            }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(.orange)
                            Text("Unable to load image")
                                .font(.system(size: 13, weight: .medium))
                            Text(item.relativePath)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(40)
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(Color(NSColor.underPageBackgroundColor))
        }
    }
    
    private var genericFileCanvas: some View {
        VStack(spacing: 16) {
            Image(systemName: item.iconName)
                .font(.system(size: 54))
                .foregroundColor(.accentColor)
            
            Text(item.displayName)
                .font(.system(size: 16, weight: .semibold))
            
            HStack(spacing: 12) {
                Text(item.formattedSize)
                Text("•")
                Text("Modified \(item.formattedModifiedDate)")
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            
            Button("Open in Default App") {
                NSWorkspace.shared.open(item.url)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}

