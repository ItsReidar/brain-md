//
//  GemmaChatView.swift
//  brain-md
//

import SwiftUI

/// The "Gemma Chat" window: a free-form conversation with the on-device model.
struct GemmaChatView: View {
    static let windowID = "gemma-chat"

    @ObservedObject var chat: GemmaChat
    @ObservedObject var vault: VaultManager
    @ObservedObject private var modelManager = LocalModelManager.shared
    @AppStorage(LocalModelManager.enabledDefaultsKey) private var isAIEnabled = false
    @AppStorage("ai_chat_include_note") private var includeNote = true
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""
    @FocusState private var isInputFocused: Bool

    private var isAvailable: Bool { isAIEnabled && modelManager.state.status == .ready }

    private var openNote: NoteItem? {
        guard let item = vault.selectedItem, item.isMarkdown else { return nil }
        return item
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAvailable {
                transcript
                Divider()
                composer
            } else {
                unavailable
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { chat.reset() }
                    .disabled(chat.messages.isEmpty)
                    .help("Start a new conversation")
            }
        }
        .onAppear { isInputFocused = true }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if chat.messages.isEmpty {
                    Text("Ask Gemma anything. Everything runs on this Mac.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
                ForEach(chat.messages) { message in
                    ChatBubble(
                        message: message,
                        isStreaming: chat.isResponding && message.id == chat.messages.last?.id,
                        canInsert: openNote != nil,
                        onInsert: insert)
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $includeNote) {
                Text(openNote.map { "Include current note (\($0.displayName))" } ?? "Include current note")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .disabled(openNote == nil)
            .help("Gemma sees the open note with your message. It's sent again only when it changes.")

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Gemma", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .padding(8)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(8)
                    .focused($isInputFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Message")

                if chat.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { chat.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the answer (⌘.)")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (Return). Shift-Return adds a line.")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)
        }
        .padding(12)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundColor(.secondary)
            Text(isAIEnabled ? "Gemma 4 isn't ready yet." : "On-device AI is turned off.")
                .font(.headline)
            Text("Chat needs the Gemma 4 model on this Mac.")
                .foregroundColor(.secondary)
            Button("Open Settings…") { openSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func send() {
        guard !chat.isResponding else { return }
        let note = includeNote
            ? openNote.map { GemmaChat.NoteContext(title: $0.displayName, content: vault.editorContent) }
            : nil
        chat.send(draft, note: note)
        draft = ""
    }

    private func insert(_ text: String) {
        guard openNote != nil else { return }
        vault.editorContent += "\n\n" + text + "\n"
        vault.hasUnsavedChanges = true
    }
}

private struct ChatBubble: View {
    let message: GemmaChat.Message
    let isStreaming: Bool
    let canInsert: Bool
    let onInsert: (String) -> Void
    @State private var didCopy = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            content
                .textSelection(.enabled)
                .padding(10)
                .background(background)
                .cornerRadius(10)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser, !isStreaming, !message.isError, !message.text.isEmpty {
                HStack(spacing: 12) {
                    Button(didCopy ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        didCopy = true
                    }
                    Button("Insert into Note") { onInsert(message.text) }
                        .disabled(!canInsert)
                        .help(canInsert ? "Add this answer below the open note" : "Open a note first")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.isError {
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        } else if !isUser, message.text.isEmpty {
            if isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundColor(.secondary)
                }
            } else {
                Text("Stopped").foregroundColor(.secondary)
            }
        } else {
            Text(Self.markdown(message.text))
        }
    }

    private var background: Color {
        if message.isError { return Color.red.opacity(0.08) }
        return isUser ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)
    }

    /// Inline Markdown (bold, italics, code, links) with line breaks kept; falls back to plain text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}
