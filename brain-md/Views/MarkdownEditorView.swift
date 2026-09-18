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
        
        let theme = MarkdownNSTheme(theme: currentTheme)
        scrollView.backgroundColor = theme.background
        
        let textView = MarkdownNSTextView()
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
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        textView.string = text
        context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
        
        scrollView.documentView = textView
        return scrollView
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
        
        if textView.string != text {
            context.coordinator.isUpdating = true
            let selectedRanges = textView.selectedRanges
            textView.string = text
            if let first = selectedRanges.first?.rangeValue, first.location + first.length <= (text as NSString).length {
                textView.setSelectedRange(first)
            }
            context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
            context.coordinator.isUpdating = false
        } else {
            // Re-highlight if theme or font configuration changed
            if context.coordinator.lastThemeId != currentTheme.id ||
               context.coordinator.lastFontSize != fontSize ||
               context.coordinator.lastFontDesign != fontDesign {
                context.coordinator.applyHighlighting(to: textView, theme: currentTheme, fontSize: fontSize, fontDesign: fontDesign)
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
        return NSFont(descriptor: descriptorWithDesign, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    
    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacMarkdownEditorView
        var isUpdating = false
        var lastThemeId: String = ""
        var lastFontSize: Double = 0
        var lastFontDesign: String = ""
        
        init(_ parent: MacMarkdownEditorView) {
            self.parent = parent
        }
        
        public func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let currentString = textView.string
            if parent.text != currentString {
                parent.text = currentString
            }
            applyHighlighting(to: textView, theme: parent.currentTheme, fontSize: parent.fontSize, fontDesign: parent.fontDesign)
        }
        
        func applyHighlighting(to textView: NSTextView, theme: TerminalTheme, fontSize: Double, fontDesign: String) {
            guard let storage = textView.textStorage else { return }
            lastThemeId = theme.id
            lastFontSize = fontSize
            lastFontDesign = fontDesign
            
            let nsTheme = MarkdownNSTheme(theme: theme)
            let baseFont = parent.makeBaseFont(size: CGFloat(fontSize), design: fontDesign)
            
            let selectedRange = textView.selectedRange()
            textView.undoManager?.disableUndoRegistration()
            storage.beginEditing()
            MarkdownSyntaxHighlighter.highlight(textStorage: storage, theme: nsTheme, baseFont: baseFont)
            storage.endEditing()
            textView.undoManager?.enableUndoRegistration()
            
            if selectedRange.location + selectedRange.length <= (storage.string as NSString).length {
                textView.setSelectedRange(selectedRange)
            }
        }
    }
}

// MARK: - Custom NSTextView with Shortcut Support

final class MarkdownNSTextView: NSTextView {
    var onSave: (() -> Void)?
    
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
