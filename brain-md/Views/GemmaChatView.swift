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

    /// Readable line length on wide windows.
    private static let contentWidth: CGFloat = 720

    private var isAvailable: Bool { isAIEnabled && modelManager.state.status == .ready }

    private var openNote: NoteItem? {
        guard let item = vault.selectedItem, item.isMarkdown else { return nil }
        return item
    }

    private var isSharingNote: Bool { includeNote && openNote != nil }

    var body: some View {
        VStack(spacing: 0) {
            if isAvailable {
                if chat.messages.isEmpty { emptyState } else { transcript }
                composer
            } else {
                unavailable
            }
        }
        .frame(minWidth: 420, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    chat.reset()
                    isInputFocused = true
                }
                .disabled(chat.messages.isEmpty)
                .help("Start a new conversation")
            }
        }
        .onAppear { isInputFocused = true }
    }

    // MARK: - Conversation

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(chat.messages) { message in
                    if message.role == .user {
                        UserMessageView(text: message.text)
                    } else {
                        AssistantMessageView(
                            message: message,
                            isStreaming: chat.isResponding && message.id == chat.messages.last?.id,
                            canInsert: openNote != nil,
                            onInsert: insert)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: Self.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            GemmaAvatar(size: 48)
            VStack(spacing: 4) {
                Text("How can I help?")
                    .font(.system(size: 20, weight: .semibold))
                Text("Gemma runs entirely on this Mac. Nothing you type leaves it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(suggestions, id: \.title) { suggestion in
                    Button { use(suggestion) } label: {
                        Label(suggestion.title, systemImage: suggestion.icon)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(SuggestionButtonStyle())
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 8)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Message Gemma", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Message")

                HStack(spacing: 8) {
                    noteChip
                    Spacer(minLength: 8)
                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isInputFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12)))
            .onTapGesture { isInputFocused = true }

            Text("Return to send · ⌥Return for a new line · Answers can be wrong")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .frame(maxWidth: Self.contentWidth + 32)
        .frame(maxWidth: .infinity)
    }

    private var noteChip: some View {
        Button { includeNote.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isSharingNote ? "doc.text.fill" : "doc.text")
                    .foregroundStyle(isSharingNote ? Color.accentColor : .secondary)
                Text(openNote?.displayName ?? "No note open")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(openNote != nil && !includeNote)
                    .foregroundStyle(isSharingNote ? .primary : .secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSharingNote ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(openNote == nil)
        .help(openNote == nil
            ? "Open a note to give Gemma its contents"
            : includeNote ? "Gemma sees this note with your message. Click to leave it out."
                : "Click to let Gemma see this note")
        .accessibilityLabel("Include current note")
        .accessibilityValue(isSharingNote ? "On" : "Off")
    }

    @ViewBuilder
    private var sendButton: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if chat.isResponding {
            Button(action: chat.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop the answer (⌘.)")
            .accessibilityLabel("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        VStack(spacing: 12) {
            GemmaAvatar(size: 48).saturation(0.2)
            Text(isAIEnabled ? "Gemma 4 isn't ready yet" : "On-device AI is turned off")
                .font(.system(size: 17, weight: .semibold))
            Text(isAIEnabled
                ? "Chat becomes available once the model has finished downloading."
                : "Turn it on to download Gemma 4 (6.8 GB) and chat privately on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Settings…") { openSettings() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Actions

    private struct Suggestion {
        let title: String
        let icon: String
        let prompt: String
        /// Prompts that need the user's own text are put in the field instead of being sent.
        let sendsImmediately: Bool
    }

    private var suggestions: [Suggestion] {
        if openNote != nil, includeNote {
            return [
                Suggestion(title: "Summarize this note", icon: "text.alignleft",
                           prompt: "Summarize this note in a few bullet points.", sendsImmediately: true),
                Suggestion(title: "List the open questions", icon: "questionmark.bubble",
                           prompt: "What questions does this note leave open?", sendsImmediately: true),
                Suggestion(title: "Find the action items", icon: "checklist",
                           prompt: "List the action items in this note as a checklist.", sendsImmediately: true),
                Suggestion(title: "Suggest a better title", icon: "textformat",
                           prompt: "Suggest three better titles for this note.", sendsImmediately: true),
            ]
        }
        return [
            Suggestion(title: "Explain a concept", icon: "lightbulb",
                       prompt: "Explain in simple terms: ", sendsImmediately: false),
            Suggestion(title: "Draft an email", icon: "envelope",
                       prompt: "Draft a short, friendly email about ", sendsImmediately: false),
            Suggestion(title: "Brainstorm ideas", icon: "sparkles",
                       prompt: "Brainstorm ten ideas for ", sendsImmediately: false),
            Suggestion(title: "Translate text", icon: "globe",
                       prompt: "Translate into Dutch: ", sendsImmediately: false),
        ]
    }

    private func use(_ suggestion: Suggestion) {
        draft = suggestion.prompt
        if suggestion.sendsImmediately { send() } else { isInputFocused = true }
    }

    private func send() {
        guard !chat.isResponding else { return }
        let note = includeNote
            ? openNote.map { GemmaChat.NoteContext(title: $0.displayName, content: vault.editorContent) }
            : nil
        chat.send(draft, note: note)
        draft = ""
        isInputFocused = true
    }

    private func insert(_ text: String) {
        guard openNote != nil else { return }
        vault.editorContent += "\n\n" + text + "\n"
        vault.hasUnsavedChanges = true
    }
}

// MARK: - Messages

private struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14)))
        }
    }
}

private struct AssistantMessageView: View {
    let message: GemmaChat.Message
    let isStreaming: Bool
    let canInsert: Bool
    let onInsert: (String) -> Void
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GemmaAvatar(size: 26)
            VStack(alignment: .leading, spacing: 8) {
                content
                if !isStreaming, !message.isError, !message.text.isEmpty { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.isError {
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        } else if message.text.isEmpty {
            if isStreaming {
                TypingIndicator()
            } else {
                Text("Stopped before answering.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else {
            ChatMarkdownView(markdown: message.text)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            MessageActionButton(title: didCopy ? "Copied" : "Copy", icon: didCopy ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                didCopy = true
            }
            MessageActionButton(title: "Insert into Note", icon: "text.insert") { onInsert(message.text) }
                .disabled(!canInsert)
                .help(canInsert ? "Add this answer below the open note" : "Open a note first")
        }
    }
}

private struct MessageActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(isHovered && isEnabled ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovered && isEnabled ? 0.07 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }
}

/// Gemma's mark: sparkles on a violet disc, the colour the app uses for on-device AI.
private struct GemmaAvatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(LinearGradient(
                    colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.43, green: 0.24, blue: 0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
            .accessibilityHidden(true)
    }
}

/// Three pulsing dots while Gemma prepares its answer; static with Reduce Motion.
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(reduceMotion ? 0.6 : (isAnimating ? 1 : 0.25))
                    .animation(
                        reduceMotion ? nil
                            : .easeInOut(duration: 0.5).repeatForever().delay(Double(index) * 0.16),
                        value: isAnimating)
            }
        }
        .padding(.vertical, 6)
        .onAppear { isAnimating = true }
        .accessibilityElement()
        .accessibilityLabel("Gemma is thinking")
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered ? 0.07 : 0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
            .onHover { isHovered = $0 }
    }
}

// MARK: - Markdown

/// Compact Markdown for chat answers, using the preview's parser and code blocks with chat-sized type.
struct ChatMarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownPreviewView.parseDocument(markdown).blocks
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .font(.system(size: 14))
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ block: MarkdownPreviewView.MarkdownBlock) -> some View {
        switch block {
        case .h1(let text), .h2(let text):
            Text(Self.inline(text)).font(.system(size: 17, weight: .semibold)).padding(.top, 4)
        case .h3(let text), .h4(let text), .h5(let text), .h6(let text):
            Text(Self.inline(text)).font(.system(size: 15, weight: .semibold)).padding(.top, 2)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .listItem(let ordered, let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordered ? "\(number)." : "•")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(Self.inline(text))
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .taskItem(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.accentColor : .secondary)
                    .accessibilityLabel(done ? "Done" : "To do")
                Text(Self.inline(text))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .mermaidDiagram(let code):
            CodeBlockView(language: "mermaid", code: code)
        case .blockquote(let text):
            quote(Text(Self.inline(text)), tint: .secondary)
        case .alert(let type, let text):
            quote(Text("\(Text(type.title + ":").bold()) \(Text(Self.inline(text)))"), tint: .accentColor)
        case .table(let headers, _, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { ForEach(headers.indices, id: \.self) { Text(Self.inline(headers[$0])).fontWeight(.semibold) } }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow { ForEach(rows[row].indices, id: \.self) { Text(Self.inline(rows[row][$0])) } }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        case .collapsible(let summary, let content):
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.inline(summary)).fontWeight(.semibold)
                ChatMarkdownView(markdown: content)
            }
        case .definitionList(let term, let definitions):
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.inline(term)).fontWeight(.semibold)
                ForEach(definitions.indices, id: \.self) { Text(Self.inline(definitions[$0])).padding(.leading, 16) }
            }
        case .rawHTML(let html):
            Text(html).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        case .image(let alt, _, _):
            Label(alt.isEmpty ? "Image" : alt, systemImage: "photo").foregroundStyle(.secondary)
        }
    }

    private func quote(_ text: Text, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(0.6)).frame(width: 3)
            text.foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inline(_ text: String) -> AttributedString {
        MarkdownPreviewView.parseStaticAttributedString(text)
    }
}

#if DEBUG
#Preview("Conversation") {
    let chat = GemmaChat()
    chat.loadForPreview([
        .init(role: .user, text: "What did we decide about the launch?", prompt: ""),
        .init(role: .assistant, text: """
            ### Launch decisions
            The team agreed to **slip the launch by two weeks** because the payment certification failed.

            - Move the release to **24 October**
            - [ ] Tell support (owner: *Lotte*)
            """, prompt: ""),
        .init(role: .user, text: "Draft a short message to support about it.", prompt: ""),
        .init(role: .assistant, text: "", prompt: ""),
    ], responding: true)
    return GemmaChatView(chat: chat, vault: .shared).frame(width: 560, height: 720)
}
#endif
