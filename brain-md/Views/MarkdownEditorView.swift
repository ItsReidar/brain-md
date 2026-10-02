//
//  MarkdownEditorView.swift
//  brain-md
//

import SwiftUI
import AppKit

public struct MarkdownEditorView: View {
    @Binding var text: String
    var onSave: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("editor_font_size") private var fontSize: Double = 14.0
    @AppStorage("editor_font_design") private var fontDesign: String = "monospaced"
    
    public init(text: Binding<String>, onSave: @escaping () -> Void) {
        self._text = text
        self.onSave = onSave
    }
    
    public var body: some View {
        let theme = themeManager.currentTheme(for: colorScheme)
        MacMarkdownEditorView(
            text: $text,
            currentTheme: theme,
            fontSize: fontSize,
            fontDesign: fontDesign,
            onSave: onSave
        )
        .background(theme.background)
    }
}

// MARK: - Native AppKit Markdown Editor View

public struct MacMarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var currentTheme: TerminalTheme
    var fontSize: Double
    var fontDesign: String
    var onSave: () -> Void
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true
        scrollView.canDrawConcurrently = true
        
        let theme = MarkdownNSTheme(theme: currentTheme)
        scrollView.backgroundColor = theme.background
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        
        let textView = MarkdownNSTextView()
        textView.wantsLayer = true
        textView.onSave = onSave
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = theme.background
        textView.textColor = theme.foreground
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selection,
            .foregroundColor: theme.foreground
        ]
        
        let baseFont = makeBaseFont(size: CGFloat(fontSize), design: fontDesign)
        textView.font = baseFont
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0.0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        // Guarantee contiguous layout to prevent viewport jump on attribute edits
        textView.layoutManager?.allowsNonContiguousLayout = false
        
        // Disable automatic dash/quote/text substitutions to preserve Markdown syntax like ---
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.typingAttributes[NSAttributedString.Key.ligature] = 0

        // Attach before inserting text: the clip view is not yet flipped while it adopts its
        // document view, and laying out existing text at that moment makes NSLayoutManager
        // grow the text view upward, leaving its frame origin thousands of points below zero.
        scrollView.documentView = textView
        textView.string = text
        context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
        textView.adjustFrameToFitContent()

        ScrollSyncCoordinator.shared.registerEditor(scrollView)
        return scrollView
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        ScrollSyncCoordinator.shared.unregisterEditor(scrollView)
    }
    
    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        context.coordinator.parent = self
        textView.onSave = onSave
        
        let theme = MarkdownNSTheme(theme: currentTheme)
        if textView.backgroundColor != theme.background {
            textView.backgroundColor = theme.background
            scrollView.backgroundColor = theme.background
        }
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selection,
            .foregroundColor: theme.foreground
        ]
        textView.typingAttributes[NSAttributedString.Key.ligature] = 0
        
        if textView.string != text {
            context.coordinator.isUpdating = true
            let selectedRanges = textView.selectedRanges
            textView.string = text
            if let first = selectedRanges.first?.rangeValue, first.location + first.length <= (text as NSString).length {
                textView.setSelectedRange(first)
            }
            context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
            textView.adjustFrameToFitContent()
            context.coordinator.isUpdating = false
        } else {
            // Re-highlight if theme or font configuration changed
            if context.coordinator.lastThemeId != currentTheme.id ||
               context.coordinator.lastFontSize != fontSize ||
               context.coordinator.lastFontDesign != fontDesign {
                context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
                textView.adjustFrameToFitContent()
            }
        }
    }
    
    fileprivate func makeBaseFont(size: CGFloat, design: String) -> NSFont {
        let fontDescriptor = NSFont.systemFont(ofSize: size).fontDescriptor
        let descriptorWithDesign: NSFontDescriptor
        switch design {
        case "monospaced":
            descriptorWithDesign = fontDescriptor.withDesign(.monospaced) ?? fontDescriptor
        case "rounded":
            descriptorWithDesign = fontDescriptor.withDesign(.rounded) ?? fontDescriptor
        case "serif":
            descriptorWithDesign = fontDescriptor.withDesign(.serif) ?? fontDescriptor
        default:
            descriptorWithDesign = fontDescriptor
        }
        
        // Explicitly disable ligatures on font descriptor so three dashes (---) are not joined into ligatures
        let noLigaturesDescriptor = descriptorWithDesign.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOffSelector
                ]
            ]
        ])
        
        return NSFont(descriptor: noLigaturesDescriptor, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    
    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacMarkdownEditorView
        var isUpdating = false
        var lastThemeId: String = ""
        var lastFontSize: Double = 0
        var lastFontDesign: String = ""
        
        private var pendingTextSyncTask: Task<Void, Never>?
        private var pendingHighlightTask: Task<Void, Never>?
        
        init(_ parent: MacMarkdownEditorView) {
            self.parent = parent
        }
        
        deinit {
            pendingTextSyncTask?.cancel()
            pendingHighlightTask?.cancel()
        }
        
        public func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let currentString = textView.string
            
            // 1. Debounce preview text synchronization (~90ms) for silky 120 FPS typing responsiveness
            pendingTextSyncTask?.cancel()
            pendingTextSyncTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard let self = self, !Task.isCancelled else { return }
                if self.parent.text != currentString {
                    self.parent.text = currentString
                }
            }
            
            // 2. Debounce full-document syntax highlighting pass (~40ms)
            pendingHighlightTask?.cancel()
            pendingHighlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.applyHighlighting(to: textView, theme: self.parent.currentTheme, fontSize: self.parent.fontSize, fontDesign: self.parent.fontDesign)
            }
        }
        
        func flushPendingSync(from textView: NSTextView) {
            pendingTextSyncTask?.cancel()
            pendingTextSyncTask = nil
            let currentString = textView.string
            if parent.text != currentString {
                parent.text = currentString
            }
        }
        
        func applyHighlighting(to textView: NSTextView, theme: TerminalTheme, fontSize: Double, fontDesign: String) {
            guard let storage = textView.textStorage else { return }
            lastThemeId = theme.id
            lastFontSize = fontSize
            lastFontDesign = fontDesign
            
            let nsTheme = MarkdownNSTheme(theme: theme)
            let baseFont = parent.makeBaseFont(size: CGFloat(fontSize), design: fontDesign)
            
            let selectedRange = textView.selectedRange()
            let clipView = textView.enclosingScrollView?.contentView
            let savedOrigin = clipView?.bounds.origin
            
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            MarkdownSyntaxHighlighter.highlight(textStorage: storage, theme: nsTheme, baseFont: baseFont)
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
            
            if selectedRange.location + selectedRange.length <= (storage.string as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
            
            if let clipView = clipView, let origin = savedOrigin {
                if textView.window?.firstResponder == textView {
                    textView.scrollRangeToVisible(selectedRange)
                } else {
                    clipView.scroll(to: origin)
                    textView.enclosingScrollView?.reflectScrolledClipView(clipView)
                }
            }
        }
    }
}

// MARK: - Custom NSTextView with Shortcut Support, Auto-Pairing & Markdown Formatting

final class MarkdownNSTextView: NSTextView {
    var onSave: (() -> Void)?
    private var formatObserver: NSObjectProtocol?
    
    deinit {
        if let observer = formatObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    /// Dynamically resizes the NSTextView's frame height to match the text layout.
    /// In AppKit, NSTextView with isVerticallyResizable only grows; it never shrinks
    /// when shorter documents are loaded, causing bloated scroll ranges and blank voids.
    func adjustFrameToFitContent() {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let scrollView = self.enclosingScrollView else { return }
        // A document view must sit at its clip view's origin; anything else shifts every
        // scroll offset (and the sync coordinator's notion of "top").
        if frame.origin != .zero {
            setFrameOrigin(.zero)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let minHeight = scrollView.contentSize.height
        let targetHeight = max(minHeight, ceil(usedRect.height + textContainerInset.height * 2))
        if abs(self.frame.height - targetHeight) > 1.0 {
            self.setFrameSize(NSSize(width: self.frame.width, height: targetHeight))
        }
    }
    
    override func didChangeText() {
        super.didChangeText()
        adjustFrameToFitContent()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupFormatObserver()
        }
    }
    
    func setupFormatObserver() {
        guard formatObserver == nil else { return }
        formatObserver = NotificationCenter.default.addObserver(
            forName: MarkdownFormatService.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let element = notification.object as? MarkdownFormatElement else { return }
            // Only apply if view is attached to a window
            guard self.window != nil else { return }
            self.applyFormatElement(element)
        }
    }
    
    func applyFormatElement(_ element: MarkdownFormatElement) {
        let result = MarkdownFormatService.format(
            element: element,
            fullText: self.string,
            selectedRange: self.selectedRange()
        )
        if shouldChangeText(in: result.replacementRange, replacementString: result.replacementText) {
            replaceCharacters(in: result.replacementRange, with: result.replacementText)
            didChangeText()
            setSelectedRange(result.newSelectedRange)
            scrollRangeToVisible(result.newSelectedRange)
            window?.makeFirstResponder(self)
        }
    }
    
    override func resignFirstResponder() -> Bool {
        (delegate as? MacMarkdownEditorView.Coordinator)?.flushPendingSync(from: self)
        return super.resignFirstResponder()
    }
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "s" {
                (delegate as? MacMarkdownEditorView.Coordinator)?.flushPendingSync(from: self)
                onSave?()
                return true
            } else if event.charactersIgnoringModifiers == "b" {
                applyFormatElement(.bold)
                return true
            } else if event.charactersIgnoringModifiers == "i" {
                applyFormatElement(.italic)
                return true
            } else if event.charactersIgnoringModifiers == "k" {
                applyFormatElement(.link)
                return true
            } else if event.charactersIgnoringModifiers == "e" {
                applyFormatElement(.inlineCode)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    
    // MARK: - Auto-Pairing & Delimiter Autocomplete
    
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = (string as? NSString) as String? ?? (string as? NSAttributedString)?.string else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        
        let targetRange = replacementRange.location != NSNotFound ? replacementRange : selectedRange()
        let currentString = self.string as NSString
        
        // 1. Selection Wrapping
        if targetRange.length > 0 && targetRange.location + targetRange.length <= currentString.length {
            let selectedText = currentString.substring(with: targetRange)
            let wrapped: String?
            switch text {
            case "'": wrapped = "'\(selectedText)'"
            case "\"": wrapped = "\"\(selectedText)\""
            case "(": wrapped = "(\(selectedText))"
            case "[": wrapped = "[\(selectedText)]"
            case "{": wrapped = "{\(selectedText)}"
            case "<": wrapped = "<\(selectedText)>"
            case "`": wrapped = "`\(selectedText)`"
            case "*": wrapped = "*\(selectedText)*"
            case "_": wrapped = "_\(selectedText)_"
            case "~": wrapped = "~~\(selectedText)~~"
            default: wrapped = nil
            }
            
            if let replacement = wrapped {
                if shouldChangeText(in: targetRange, replacementString: replacement) {
                    replaceCharacters(in: targetRange, with: replacement)
                    didChangeText()
                    setSelectedRange(NSRange(location: targetRange.location, length: (replacement as NSString).length))
                    return
                }
            }
        }
        
        // 2. Cursor at point (no selection): Overtyping closing pair or Auto-Pairing
        if targetRange.length == 0 && targetRange.location <= currentString.length {
            let loc = targetRange.location
            let nextChar: String? = (loc < currentString.length) ? currentString.substring(with: NSRange(location: loc, length: 1)) : nil
            
            // Overtype protection: if user types closing char when cursor is right before it, advance cursor
            if let next = nextChar, (
                (text == "'" && next == "'") ||
                (text == "\"" && next == "\"") ||
                (text == ")" && next == ")") ||
                (text == "]" && next == "]") ||
                (text == "}" && next == "}") ||
                (text == ">" && next == ">") ||
                (text == "`" && next == "`")
            ) {
                setSelectedRange(NSRange(location: loc + 1, length: 0))
                return
            }
            
            // Triple backtick detection for Code Blocks: typing 3rd backtick expands to fenced code block
            if text == "`" && loc >= 2 {
                let prevTwo = currentString.substring(with: NSRange(location: loc - 2, length: 2))
                if prevTwo == "``" {
                    let codeBlockSnippet = "`\n\n```"
                    if shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: codeBlockSnippet) {
                        replaceCharacters(in: NSRange(location: loc, length: 0), with: codeBlockSnippet)
                        didChangeText()
                        setSelectedRange(NSRange(location: loc + 2, length: 0))
                        return
                    }
                }
            }
            
            // Double asterisk (**) for bold auto-pairing
            if text == "*" && loc >= 1 {
                let prevOne = currentString.substring(with: NSRange(location: loc - 1, length: 1))
                if prevOne == "*" {
                    let boldSnippet = "**"
                    if shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: boldSnippet) {
                        replaceCharacters(in: NSRange(location: loc, length: 0), with: boldSnippet)
                        didChangeText()
                        setSelectedRange(NSRange(location: loc, length: 0))
                        return
                    }
                }
            }
            
            // Double tilde (~~) for strikethrough auto-pairing
            if text == "~" && loc >= 1 {
                let prevOne = currentString.substring(with: NSRange(location: loc - 1, length: 1))
                if prevOne == "~" {
                    let strikeSnippet = "~~"
                    if shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: strikeSnippet) {
                        replaceCharacters(in: NSRange(location: loc, length: 0), with: strikeSnippet)
                        didChangeText()
                        setSelectedRange(NSRange(location: loc, length: 0))
                        return
                    }
                }
            }
            
            // Double underscore (__) auto-pairing
            if text == "_" && loc >= 1 {
                let prevOne = currentString.substring(with: NSRange(location: loc - 1, length: 1))
                if prevOne == "_" {
                    let underSnippet = "__"
                    if shouldChangeText(in: NSRange(location: loc, length: 0), replacementString: underSnippet) {
                        replaceCharacters(in: NSRange(location: loc, length: 0), with: underSnippet)
                        didChangeText()
                        setSelectedRange(NSRange(location: loc, length: 0))
                        return
                    }
                }
            }
            
            // Auto-pair single delimiters
            let pair: (String, Int)?
            switch text {
            case "'": pair = ("''", 1)
            case "\"": pair = ("\"\"", 1)
            case "(": pair = ("()", 1)
            case "[": pair = ("[]", 1)
            case "{": pair = ("{}", 1)
            case "<": pair = ("<>", 1)
            case "`": pair = ("``", 1)
            default: pair = nil
            }
            
            if let (pairText, offset) = pair {
                if shouldChangeText(in: targetRange, replacementString: pairText) {
                    replaceCharacters(in: targetRange, with: pairText)
                    didChangeText()
                    setSelectedRange(NSRange(location: loc + offset, length: 0))
                    return
                }
            }
        }
        
        super.insertText(string, replacementRange: replacementRange)
    }
    
    // MARK: - Balanced Pair Deletion on Backspace
    
    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0 && sel.location > 0 {
            let nsString = self.string as NSString
            let loc = sel.location
            
            // 1. Single character pairs ('' "" () [] {} <> ``)
            if loc < nsString.length {
                let prev = nsString.substring(with: NSRange(location: loc - 1, length: 1))
                let next = nsString.substring(with: NSRange(location: loc, length: 1))
                let isPair = (
                    (prev == "'" && next == "'") ||
                    (prev == "\"" && next == "\"") ||
                    (prev == "(" && next == ")") ||
                    (prev == "[" && next == "]") ||
                    (prev == "{" && next == "}") ||
                    (prev == "<" && next == ">") ||
                    (prev == "`" && next == "`")
                )
                if isPair {
                    let deleteRange = NSRange(location: loc - 1, length: 2)
                    if shouldChangeText(in: deleteRange, replacementString: "") {
                        replaceCharacters(in: deleteRange, with: "")
                        didChangeText()
                        setSelectedRange(NSRange(location: loc - 1, length: 0))
                        return
                    }
                }
            }
            
            // 2. Double character pairs (**|** or ~~|~~ or __|__)
            if loc >= 2 && loc + 2 <= nsString.length {
                let prevTwo = nsString.substring(with: NSRange(location: loc - 2, length: 2))
                let nextTwo = nsString.substring(with: NSRange(location: loc, length: 2))
                if (prevTwo == "**" && nextTwo == "**") ||
                   (prevTwo == "~~" && nextTwo == "~~") ||
                   (prevTwo == "__" && nextTwo == "__") {
                    let deleteRange = NSRange(location: loc - 2, length: 4)
                    if shouldChangeText(in: deleteRange, replacementString: "") {
                        replaceCharacters(in: deleteRange, with: "")
                        didChangeText()
                        setSelectedRange(NSRange(location: loc - 2, length: 0))
                        return
                    }
                }
            }
        }
        
        super.deleteBackward(sender)
    }
    
    // MARK: - Smart List Continuation on Enter
    
    // MARK: - Tab & Shift-Tab (Indent / Outdent)
    
    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let nsString = self.string as NSString
        guard sel.location != NSNotFound, sel.location + sel.length <= nsString.length else {
            super.insertTab(sender)
            return
        }
        
        let lineRange = nsString.lineRange(for: sel)
        let selectedLinesText = nsString.substring(with: lineRange)
        
        if sel.length > 0 || isListLine(selectedLinesText) {
            let lines = selectedLinesText.components(separatedBy: "\n")
            var newLines: [String] = []
            for (idx, line) in lines.enumerated() {
                if idx == lines.count - 1 && line.isEmpty {
                    newLines.append(line)
                } else {
                    newLines.append("  " + line)
                }
            }
            let replacement = newLines.joined(separator: "\n")
            if shouldChangeText(in: lineRange, replacementString: replacement) {
                replaceCharacters(in: lineRange, with: replacement)
                didChangeText()
                if sel.length > 0 {
                    let addedSpaces = 2 * lines.filter({ !$0.isEmpty }).count
                    setSelectedRange(NSRange(location: min(sel.location + 2, (self.string as NSString).length), length: min(sel.length + addedSpaces - 2, max(0, (self.string as NSString).length - (sel.location + 2)))))
                } else {
                    setSelectedRange(NSRange(location: min(sel.location + 2, (self.string as NSString).length), length: 0))
                }
            }
        } else {
            if shouldChangeText(in: sel, replacementString: "  ") {
                replaceCharacters(in: sel, with: "  ")
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + 2, length: 0))
            }
        }
    }
    
    override func insertBacktab(_ sender: Any?) {
        let sel = selectedRange()
        let nsString = self.string as NSString
        guard sel.location != NSNotFound, sel.location + sel.length <= nsString.length else {
            super.insertBacktab(sender)
            return
        }
        
        let lineRange = nsString.lineRange(for: sel)
        let selectedLinesText = nsString.substring(with: lineRange)
        let lines = selectedLinesText.components(separatedBy: "\n")
        var newLines: [String] = []
        var firstLineRemoved = 0
        var totalRemoved = 0
        
        for (idx, line) in lines.enumerated() {
            if idx == lines.count - 1 && line.isEmpty {
                newLines.append(line)
                continue
            }
            var removed = 0
            if line.hasPrefix("  ") {
                newLines.append(String(line.dropFirst(2)))
                removed = 2
            } else if line.hasPrefix(" ") {
                newLines.append(String(line.dropFirst(1)))
                removed = 1
            } else if line.hasPrefix("\t") {
                newLines.append(String(line.dropFirst(1)))
                removed = 1
            } else {
                newLines.append(line)
            }
            if idx == 0 {
                firstLineRemoved = removed
            }
            totalRemoved += removed
        }
        
        if totalRemoved > 0 {
            let replacement = newLines.joined(separator: "\n")
            if shouldChangeText(in: lineRange, replacementString: replacement) {
                replaceCharacters(in: lineRange, with: replacement)
                didChangeText()
                let newLocation = max(lineRange.location, sel.location - firstLineRemoved)
                let newLength = max(0, sel.length - (totalRemoved - firstLineRemoved))
                setSelectedRange(NSRange(location: min(newLocation, (self.string as NSString).length), length: min(newLength, max(0, (self.string as NSString).length - newLocation))))
            }
        }
    }
    
    private func isListLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") ||
               trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil ||
               trimmed.range(of: #"^[-*+]\s+\[[ xX]\]"#, options: .regularExpression) != nil
    }
    
    // MARK: - Viewport Padding for Cursor Visibility
    
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let layoutManager = self.layoutManager, let textContainer = self.textContainer else {
            super.scrollRangeToVisible(range)
            return
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        
        // Add comfortable vertical padding (40pt) so the cursor never hugs the bottom or top window edge
        let padding: CGFloat = 40.0
        rect.origin.y = max(0, rect.origin.y - padding / 2)
        rect.size.height += padding
        
        scrollToVisible(rect)
    }
    
    // MARK: - Smart List Continuation on Enter
    
    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0 {
            let nsString = self.string as NSString
            let lineRange = nsString.lineRange(for: sel)
            let lineText = nsString.substring(with: lineRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            let leadingSpaces = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
            
            // 1. Task List (- [ ] or - [x])
            if trimmed.range(of: #"^[-*+]\s+\[[ xX]\](\s*)"#, options: .regularExpression) != nil {
                let content = trimmed.replacingOccurrences(of: #"^[-*+]\s+\[[ xX]\]\s*"#, with: "", options: .regularExpression)
                if content.isEmpty {
                    if leadingSpaces.isEmpty {
                        // At root level: clear bullet to empty newline
                        if shouldChangeText(in: lineRange, replacementString: "\n") {
                            replaceCharacters(in: lineRange, with: "\n")
                            didChangeText()
                            setSelectedRange(NSRange(location: lineRange.location, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    } else {
                        // Indented: outdent by 2 spaces
                        let outdentedSpaces = String(leadingSpaces.dropLast(min(2, leadingSpaces.count)))
                        let outdentedLine = outdentedSpaces + "- [ ] \n"
                        if shouldChangeText(in: lineRange, replacementString: outdentedLine) {
                            replaceCharacters(in: lineRange, with: outdentedLine)
                            didChangeText()
                            let newPos = lineRange.location + (outdentedSpaces as NSString).length + 6
                            setSelectedRange(NSRange(location: newPos, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    }
                } else {
                    let continuation = "\n" + leadingSpaces + "- [ ] "
                    if shouldChangeText(in: sel, replacementString: continuation) {
                        replaceCharacters(in: sel, with: continuation)
                        didChangeText()
                        setSelectedRange(NSRange(location: sel.location + (continuation as NSString).length, length: 0))
                        scrollRangeToVisible(selectedRange())
                        return
                    }
                }
            }
            // 2. Unordered Bullet List (- , * , + )
            else if let bulletMatch = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                let bullet = String(trimmed[bulletMatch])
                let content = trimmed.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
                if content.isEmpty {
                    if leadingSpaces.isEmpty {
                        // At root level: clear bullet
                        if shouldChangeText(in: lineRange, replacementString: "\n") {
                            replaceCharacters(in: lineRange, with: "\n")
                            didChangeText()
                            setSelectedRange(NSRange(location: lineRange.location, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    } else {
                        // Indented: outdent by 2 spaces
                        let outdentedSpaces = String(leadingSpaces.dropLast(min(2, leadingSpaces.count)))
                        let outdentedLine = outdentedSpaces + bullet + "\n"
                        if shouldChangeText(in: lineRange, replacementString: outdentedLine) {
                            replaceCharacters(in: lineRange, with: outdentedLine)
                            didChangeText()
                            let newPos = lineRange.location + (outdentedSpaces as NSString).length + (bullet as NSString).length
                            setSelectedRange(NSRange(location: newPos, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    }
                } else {
                    let continuation = "\n" + leadingSpaces + bullet
                    if shouldChangeText(in: sel, replacementString: continuation) {
                        replaceCharacters(in: sel, with: continuation)
                        didChangeText()
                        setSelectedRange(NSRange(location: sel.location + (continuation as NSString).length, length: 0))
                        scrollRangeToVisible(selectedRange())
                        return
                    }
                }
            }
            // 3. Numbered List (1. , 2. )
            else if let numMatch = trimmed.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                let matchedText = String(trimmed[numMatch])
                let digits = matchedText.replacingOccurrences(of: #"[^\d]"#, with: "", options: .regularExpression)
                let num = Int(digits) ?? 1
                let content = trimmed.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                if content.isEmpty {
                    if leadingSpaces.isEmpty {
                        // At root level: clear number
                        if shouldChangeText(in: lineRange, replacementString: "\n") {
                            replaceCharacters(in: lineRange, with: "\n")
                            didChangeText()
                            setSelectedRange(NSRange(location: lineRange.location, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    } else {
                        // Indented: outdent by 2 spaces
                        let outdentedSpaces = String(leadingSpaces.dropLast(min(2, leadingSpaces.count)))
                        let outdentedLine = outdentedSpaces + "\(num). \n"
                        if shouldChangeText(in: lineRange, replacementString: outdentedLine) {
                            replaceCharacters(in: lineRange, with: outdentedLine)
                            didChangeText()
                            let newPos = lineRange.location + (outdentedSpaces as NSString).length + "\(num). ".count
                            setSelectedRange(NSRange(location: newPos, length: 0))
                            scrollRangeToVisible(selectedRange())
                            return
                        }
                    }
                } else {
                    let continuation = "\n" + leadingSpaces + "\(num + 1). "
                    if shouldChangeText(in: sel, replacementString: continuation) {
                        replaceCharacters(in: sel, with: continuation)
                        didChangeText()
                        setSelectedRange(NSRange(location: sel.location + (continuation as NSString).length, length: 0))
                        scrollRangeToVisible(selectedRange())
                        return
                    }
                }
            }
        }
        
        super.insertNewline(sender)
        scrollRangeToVisible(selectedRange())
    }
}
