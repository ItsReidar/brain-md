//
//  MarkdownPreviewView.swift
//  brain-md
//

import SwiftUI
import WebKit
import AppKit

public enum AlertType: String, CaseIterable, Sendable {
    case note = "NOTE"
    case tip = "TIP"
    case important = "IMPORTANT"
    case warning = "WARNING"
    case caution = "CAUTION"
    
    public var title: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }
    
    public var iconName: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "octagon.fill"
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .note: return Color(red: 0.05, green: 0.45, blue: 0.90) // GitHub blue #0969da
        case .tip: return Color(red: 0.10, green: 0.60, blue: 0.25) // GitHub green #1a7f37
        case .important: return Color(red: 0.51, green: 0.25, blue: 0.85) // GitHub purple #8250df
        case .warning: return Color(red: 0.85, green: 0.45, blue: 0.0) // GitHub amber #9a6700
        case .caution: return Color(red: 0.82, green: 0.15, blue: 0.15) // GitHub red #cf222e
        }
    }
    
    public var backgroundColor: Color {
        accentColor.opacity(0.08)
    }
}

public struct MarkdownPreviewView: View {
    public let markdown: String
    public var onTagSelected: ((String) -> Void)?
    
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("preview_content_width") private var previewContentWidth: Double = 850.0
    
    public init(markdown: String, onTagSelected: ((String) -> Void)? = nil) {
        self.markdown = markdown
        self.onTagSelected = onTagSelected
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No content to preview")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Start writing Markdown in the editor to see live formatted preview.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 60)
                } else {
                    let parsed = FrontmatterParser.parse(markdown)
                    
                    if let fm = parsed.frontmatter, !fm.isEmpty {
                        FrontmatterCardView(frontmatter: fm, onTagSelected: onTagSelected)
                            .padding(.bottom, 6)
                    }
                    
                    let bodyText = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bodyText.isEmpty {
                        let doc = Self.parseDocument(parsed.body)
                        ForEach(doc.blocks.indices, id: \.self) { idx in
                            renderBlock(doc.blocks[idx])
                        }
                        
                        if !doc.footnotes.isEmpty {
                            Divider()
                                .padding(.top, 20)
                            Text("Footnotes")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.secondary)
                            ForEach(doc.footnotes.indices, id: \.self) { idx in
                                let fn = doc.footnotes[idx]
                                HStack(alignment: .top, spacing: 6) {
                                    Text("[\(fn.id)]")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                    Text(parseAttributedString(fn.text))
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: previewContentWidth >= 2000 ? .infinity : CGFloat(max(300, previewContentWidth)), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    // MARK: - Block Data Models
    
    public struct FootnoteItem: Sendable, Equatable {
        public let id: String
        public let text: String
        
        public init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }
    
    public struct ParsedDocument: Sendable {
        public let blocks: [MarkdownBlock]
        public let footnotes: [FootnoteItem]
        
        public init(blocks: [MarkdownBlock], footnotes: [FootnoteItem]) {
            self.blocks = blocks
            self.footnotes = footnotes
        }
    }
    
    public enum MarkdownBlock: Sendable {
        case h1(String)
        case h2(String)
        case h3(String)
        case h4(String)
        case h5(String)
        case h6(String)
        case alert(type: AlertType, text: String)
        case codeBlock(lang: String, code: String)
        case mermaidDiagram(code: String)
        case blockquote(String)
        case taskItem(done: Bool, text: String)
        case listItem(ordered: Bool, number: Int, text: String, indent: Int)
        case table(headers: [String], alignments: [TextAlignment], rows: [[String]])
        case horizontalRule
        case paragraph(String)
    }
    
    // MARK: - Document Parser & Cache
    
    private final class DocumentCacheBox: @unchecked Sendable {
        let doc: ParsedDocument
        init(_ doc: ParsedDocument) { self.doc = doc }
    }
    
    private static let documentCache: NSCache<NSString, DocumentCacheBox> = {
        let cache = NSCache<NSString, DocumentCacheBox>()
        cache.countLimit = 100
        return cache
    }()
    
    public static func parseDocument(_ text: String) -> ParsedDocument {
        let cacheKey = "\(text.hashValue)_\(text.count)" as NSString
        if let cached = documentCache.object(forKey: cacheKey) {
            return cached.doc
        }
        
        var blocks: [MarkdownBlock] = []
        var footnotes: [FootnoteItem] = []
        
        let lines = text.components(separatedBy: "\n")
        var i = 0
        
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // 1. Skip HTML Comments <!-- ... -->
            if trimmed.hasPrefix("<!--") {
                if trimmed.contains("-->") {
                    i += 1
                    continue
                }
                while i < lines.count && !lines[i].contains("-->") {
                    i += 1
                }
                i += 1
                continue
            }
            
            // 2. Code Block or Mermaid Diagram ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let codeLine = lines[i]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(codeLine)
                    i += 1
                }
                let fullCode = codeLines.joined(separator: "\n")
                if lang.lowercased() == "mermaid" {
                    blocks.append(.mermaidDiagram(code: fullCode))
                } else {
                    blocks.append(.codeBlock(lang: lang, code: fullCode))
                }
                continue
            }
            
            // 3. GitHub Alerts > [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING], > [!CAUTION]
            if isAlertStart(trimmed) {
                let alertType = extractAlertType(trimmed)
                var alertLines: [String] = []
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(">") {
                        let content = String(nextTrimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                        alertLines.append(content)
                        i += 1
                    } else if nextTrimmed.isEmpty {
                        i += 1
                        break
                    } else {
                        break
                    }
                }
                blocks.append(.alert(type: alertType, text: alertLines.joined(separator: " ")))
                continue
            }
            
            // 4. Standard Blockquote >
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = [String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)]
                i += 1
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix(">") && !isAlertStart(nextTrimmed) {
                        quoteLines.append(String(nextTrimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ")))
                continue
            }
            
            // 5. GFM Tables (| Header | Header |)
            if isTableRow(trimmed) && i + 1 < lines.count && isTableDelimiterRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headerCells = parseTableCells(trimmed)
                let alignments = parseTableAlignments(lines[i + 1].trimmingCharacters(in: .whitespaces))
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let nextTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if isTableRow(nextTrimmed) {
                        rows.append(parseTableCells(nextTrimmed))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.table(headers: headerCells, alignments: alignments, rows: rows))
                continue
            }
            
            // 6. Footnotes definition [^id]: text
            if let footnote = parseFootnoteLine(trimmed) {
                footnotes.append(footnote)
                i += 1
                continue
            }
            
            // 7. Headings (# to ######)
            if trimmed.hasPrefix("# ") {
                blocks.append(.h1(String(trimmed.dropFirst(2))))
                i += 1
                continue
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.h2(String(trimmed.dropFirst(3))))
                i += 1
                continue
            } else if trimmed.hasPrefix("### ") {
                blocks.append(.h3(String(trimmed.dropFirst(4))))
                i += 1
                continue
            } else if trimmed.hasPrefix("#### ") {
                blocks.append(.h4(String(trimmed.dropFirst(5))))
                i += 1
                continue
            } else if trimmed.hasPrefix("##### ") {
                blocks.append(.h5(String(trimmed.dropFirst(6))))
                i += 1
                continue
            } else if trimmed.hasPrefix("###### ") {
                blocks.append(.h6(String(trimmed.dropFirst(7))))
                i += 1
                continue
            }
            
            // 8. Horizontal Rules
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }
            
            // 9. Task Lists (- [ ] or - [x])
            if trimmed.hasPrefix("- [ ] ") {
                blocks.append(.taskItem(done: false, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                blocks.append(.taskItem(done: true, text: String(trimmed.dropFirst(6))))
                i += 1
                continue
            }
            
            // 10. Unordered & Ordered Lists
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                blocks.append(.listItem(ordered: false, number: 0, text: String(trimmed.dropFirst(2)), indent: indent))
                i += 1
                continue
            } else if let numMatch = parseOrderedList(trimmed) {
                blocks.append(.listItem(ordered: true, number: numMatch.number, text: numMatch.text, indent: indent))
                i += 1
                continue
            }
            
            // 11. Regular Paragraph
            if !trimmed.isEmpty {
                blocks.append(.paragraph(line))
            }
            
            i += 1
        }
        
        let doc = ParsedDocument(blocks: blocks, footnotes: footnotes)
        documentCache.setObject(DocumentCacheBox(doc), forKey: cacheKey)
        return doc
    }
    
    // MARK: - Parsing Helpers
    
    public static func isAlertStart(_ line: String) -> Bool {
        let clean = line.replacingOccurrences(of: " ", with: "").uppercased()
        return clean.hasPrefix(">[!NOTE]") ||
               clean.hasPrefix(">[!TIP]") ||
               clean.hasPrefix(">[!IMPORTANT]") ||
               clean.hasPrefix(">[!WARNING]") ||
               clean.hasPrefix(">[!CAUTION]")
    }
    
    public static func extractAlertType(_ line: String) -> AlertType {
        let clean = line.replacingOccurrences(of: " ", with: "").uppercased()
        if clean.contains("[!NOTE]") { return .note }
        if clean.contains("[!TIP]") { return .tip }
        if clean.contains("[!IMPORTANT]") { return .important }
        if clean.contains("[!WARNING]") { return .warning }
        if clean.contains("[!CAUTION]") { return .caution }
        return .note
    }
    
    public static func isTableRow(_ line: String) -> Bool {
        return line.contains("|") && line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }
    
    public static func isTableDelimiterRow(_ line: String) -> Bool {
        guard isTableRow(line) else { return false }
        let allowed = CharacterSet(charactersIn: "|- :")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    
    public static func parseTableCells(_ line: String) -> [String] {
        var raw = line.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("|") { raw.removeFirst() }
        if raw.hasSuffix("|") { raw.removeLast() }
        return raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    
    public static func parseTableAlignments(_ line: String) -> [TextAlignment] {
        let cells = parseTableCells(line)
        return cells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let hasLeft = trimmed.hasPrefix(":")
            let hasRight = trimmed.hasSuffix(":")
            if hasLeft && hasRight { return .center }
            if hasRight { return .trailing }
            return .leading
        }
    }
    
    public static func parseFootnoteLine(_ line: String) -> FootnoteItem? {
        if line.hasPrefix("[^") && line.contains("]:") {
            guard let closeBracket = line.firstIndex(of: "]"),
                  let colonIdx = line.range(of: "]:")?.upperBound else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket])
            let text = String(line[colonIdx...]).trimmingCharacters(in: .whitespaces)
            return FootnoteItem(id: id, text: text)
        }
        return nil
    }
    
    public static func parseOrderedList(_ line: String) -> (number: Int, text: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let numStr = String(line[..<dotIndex])
        guard let num = Int(numStr) else { return nil }
        let nextIndex = line.index(after: dotIndex)
        guard nextIndex < line.endIndex, line[nextIndex] == " " else { return nil }
        let text = String(line[line.index(after: nextIndex)...])
        return (num, text)
    }
    
    // MARK: - View Rendering
    
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .h1(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(parseAttributedString(text))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Divider()
            }
            .padding(.top, 14)
            .padding(.bottom, 4)
            
        case .h2(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(parseAttributedString(text))
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Divider()
            }
            .padding(.top, 10)
            .padding(.bottom, 2)
            
        case .h3(let text):
            Text(parseAttributedString(text))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .padding(.top, 6)
            
        case .h4(let text):
            Text(parseAttributedString(text))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
            
        case .h5(let text):
            Text(parseAttributedString(text))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            
        case .h6(let text):
            Text(parseAttributedString(text))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
        case .alert(let type, let text):
            renderAlert(type: type, content: text)
            
        case .codeBlock(let lang, let code):
            CodeBlockView(language: lang, code: code)
            
        case .mermaidDiagram(let code):
            MermaidDiagramView(code: code)
            
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3.5)
                Text(parseAttributedString(text))
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
            }
            .padding(.vertical, 2)
            
        case .taskItem(let done, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundColor(done ? .accentColor : .secondary)
                    .font(.system(size: 14))
                    .padding(.top, 2)
                Text(parseAttributedString(text))
                    .font(.system(size: 14))
                    .foregroundColor(done ? .secondary : .primary)
                    .strikethrough(done, color: .secondary)
            }
            
        case .listItem(let ordered, let number, let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                if ordered {
                    Text("\(number).")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                } else {
                    Circle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                }
                Text(parseAttributedString(text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent * 8))
            
        case .table(let headers, let alignments, let rows):
            renderTable(headers: headers, alignments: alignments, rows: rows)
            
        case .horizontalRule:
            Divider()
                .padding(.vertical, 8)
            
        case .paragraph(let text):
            renderParagraph(text)
        }
    }
    
    // MARK: - Component Renderers
    
    @ViewBuilder
    private func renderAlert(type: AlertType, content: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(type.accentColor)
                .frame(width: 4)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: type.iconName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(type.title)
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundColor(type.accentColor)
                
                Text(parseAttributedString(content))
                    .font(.system(size: 13.5))
                    .foregroundColor(.primary)
                    .lineSpacing(3)
            }
            .padding(.vertical, 10)
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(type.backgroundColor)
        .cornerRadius(6)
    }
    
    @ViewBuilder
    private func renderTable(headers: [String], alignments: [TextAlignment], rows: [[String]]) -> some View {
        let borderColor = Color.secondary.opacity(0.18)
        let headerBorderColor = Color.secondary.opacity(0.24)
        
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // Table Header Row
                GridRow {
                    ForEach(headers.indices, id: \.self) { cIdx in
                        let align = cIdx < alignments.count ? alignments[cIdx] : .leading
                        Text(parseAttributedString(headers[cIdx]))
                            .font(.system(size: 13, weight: .bold))
                            .multilineTextAlignment(align)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: 80, maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(for: align))
                            .background(Color(NSColor.controlBackgroundColor))
                            .overlay(alignment: .leading) {
                                if cIdx > 0 {
                                    Rectangle().fill(borderColor).frame(width: 0.5)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(headerBorderColor).frame(height: 1)
                            }
                    }
                }
                
                // Table Data Rows
                ForEach(rows.indices, id: \.self) { rIdx in
                    let row = rows[rIdx]
                    let isLastRow = (rIdx == rows.count - 1)
                    GridRow {
                        ForEach(headers.indices, id: \.self) { cIdx in
                            let align = cIdx < alignments.count ? alignments[cIdx] : .leading
                            let cellText = cIdx < row.count ? row[cIdx] : ""
                            Text(parseAttributedString(cellText))
                                .font(.system(size: 13))
                                .multilineTextAlignment(align)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(minWidth: 80, maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment(for: align))
                                .background(rIdx % 2 == 1 ? Color.primary.opacity(0.02) : Color.clear)
                                .overlay(alignment: .leading) {
                                    if cIdx > 0 {
                                        Rectangle().fill(borderColor).frame(width: 0.5)
                                    }
                                }
                                .overlay(alignment: .bottom) {
                                    if !isLastRow {
                                        Rectangle().fill(borderColor).frame(height: 0.5)
                                    }
                                }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func renderParagraph(_ text: String) -> some View {
        // Detect GitHub color swatch e.g., `#0969da`
        if let hexMatch = extractHexColor(text) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(hexMatch.color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                    )
                Text(parseAttributedString(text))
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
            }
        } else {
            Text(parseAttributedString(text))
                .font(.system(size: 14.5))
                .lineSpacing(4)
        }
    }
    
    private func frameAlignment(for align: TextAlignment) -> Alignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    
    private static let hexColorRegex = try! NSRegularExpression(pattern: "^#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$")
    
    private final class InlineStringCacheBox: @unchecked Sendable {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    
    private static let inlineStringCache: NSCache<NSString, InlineStringCacheBox> = {
        let cache = NSCache<NSString, InlineStringCacheBox>()
        cache.countLimit = 500
        return cache
    }()
    
    private func extractHexColor(_ text: String) -> (hex: String, color: Color)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if Self.hexColorRegex.firstMatch(in: trimmed, range: range) != nil {
            if let color = Color(hex: trimmed) {
                return (trimmed, color)
            }
        }
        return nil
    }
    
    // MARK: - Inline Markdown Parsing
    
    private func parseAttributedString(_ markdown: String) -> AttributedString {
        let cacheKey = "\(markdown.hashValue)_\(markdown.count)" as NSString
        if let cached = Self.inlineStringCache.object(forKey: cacheKey) {
            return cached.value
        }
        
        let sanitized = sanitizeMarkdown(markdown)
        let attributed: AttributedString
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            attributed = (try? AttributedString(markdown: sanitized, options: options)) ?? AttributedString(markdown)
        }
        Self.inlineStringCache.setObject(InlineStringCacheBox(attributed), forKey: cacheKey)
        return attributed
    }
    
    private func sanitizeMarkdown(_ text: String) -> String {
        var result = text
        
        // Convert HTML strikethrough <del> / <s> to markdown ~~
        result = result.replacingOccurrences(of: "<del>", with: "~~")
        result = result.replacingOccurrences(of: "</del>", with: "~~")
        result = result.replacingOccurrences(of: "<s>", with: "~~")
        result = result.replacingOccurrences(of: "</s>", with: "~~")
        
        return result
    }
}

// MARK: - CodeBlockView with Syntax Highlighting & Copy

struct CodeBlockView: View {
    @Environment(\.colorScheme) private var colorScheme
    let language: String
    let code: String
    
    @State private var isCopied = false
    
    var body: some View {
        let isDark = colorScheme == .dark
        let theme = SyntaxTheme.theme(for: colorScheme)
        let lang = SyntaxLanguage.from(identifier: language)
        let highlighted = SyntaxHighlighter.highlight(code: code, language: lang, theme: theme)
        
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text(lang.displayName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isDark ? Color(hex: "#8b949e")! : Color(hex: "#57606a")!)
                
                Spacer()
                
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(isCopied ? "Copied!" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(isCopied ? Color.green : (isDark ? Color(hex: "#c9d1d9")! : Color(hex: "#57606a")!))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isDark ? Color(hex: "#21262d")! : Color(hex: "#eaeef2")!)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.headerBackground)
            
            Divider()
                .background(theme.border)
            
            // Code Content with High-Contrast Syntax Highlighting
            ScrollView(.horizontal, showsIndicators: true) {
                Text(highlighted)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.border, lineWidth: 1)
        )
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

// MARK: - Frontmatter Card View

public struct FrontmatterCardView: View {
    public let frontmatter: ParsedFrontmatter
    public var onTagSelected: ((String) -> Void)? = nil
    
    @State private var isCollapsed: Bool = false
    
    public init(frontmatter: ParsedFrontmatter, onTagSelected: ((String) -> Void)? = nil) {
        self.frontmatter = frontmatter
        self.onTagSelected = onTagSelected
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                
                Text("Properties")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("\(frontmatter.properties.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                
                if !frontmatter.tags.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                        Text("\(frontmatter.tags.count)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isCollapsed.toggle()
                    }
                }) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Expand properties" : "Collapse properties")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            
            // Property Rows
            if !isCollapsed {
                Divider()
                    .opacity(0.5)
                
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(frontmatter.properties) { prop in
                        HStack(alignment: .top, spacing: 12) {
                            // Property Key with SF Symbol
                            HStack(spacing: 5) {
                                Image(systemName: iconName(for: prop.key))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.8))
                                    .frame(width: 12)
                                Text(prop.key)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 115, alignment: .leading)
                            
                            // Property Value
                            if prop.isTags && !prop.tags.isEmpty {
                                FlowLayout(spacing: 6) {
                                    ForEach(prop.tags, id: \.self) { tag in
                                        TagPillButton(tag: tag, onTagSelected: onTagSelected)
                                    }
                                }
                            } else if prop.value.lowercased() == "true" || prop.value.lowercased() == "false" {
                                let isTrue = prop.value.lowercased() == "true"
                                HStack(spacing: 4) {
                                    Image(systemName: isTrue ? "checkmark.circle.fill" : "xmark.circle")
                                        .foregroundColor(isTrue ? .green : .secondary)
                                        .font(.system(size: 11))
                                    Text(isTrue ? "True" : "False")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isTrue ? .primary : .secondary)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isTrue ? Color.green.opacity(0.1) : Color.secondary.opacity(0.08))
                                .cornerRadius(4)
                            } else if prop.value.hasPrefix("http://") || prop.value.hasPrefix("https://"),
                                      let url = URL(string: prop.value) {
                                Link(destination: url) {
                                    HStack(spacing: 4) {
                                        Text(prop.value)
                                            .font(.system(size: 12))
                                            .underline()
                                        Image(systemName: "arrow.up.forward.square")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundColor(.accentColor)
                                }
                            } else {
                                let displayVal = FrontmatterParser.stripQuotes(prop.value)
                                Text(displayVal)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.45))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }
    
    private func iconName(for key: String) -> String {
        let lower = key.lowercased()
        switch lower {
        case "tags", "tag", "keywords": return "tag.fill"
        case "title": return "character.cursor.ibeam"
        case "date", "created", "modified", "updated": return "calendar"
        case "author": return "person.fill"
        case "status": return "flag.fill"
        case "category", "categories": return "folder.fill"
        case "priority": return "exclamationmark.circle.fill"
        case "pinned": return "pin.fill"
        case "url", "link", "website": return "link"
        default: return "circle.grid.2x1.fill"
        }
    }
}

// MARK: - Interactive Tag Pill

private struct TagPillButton: View {
    let tag: String
    let onTagSelected: ((String) -> Void)?
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            onTagSelected?(tag)
        }) {
            HStack(spacing: 3) {
                Text("#")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isHovered ? .accentColor : .accentColor.opacity(0.85))
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHovered ? .primary : .primary.opacity(0.85))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(isHovered ? Color.accentColor.opacity(0.55) : Color.accentColor.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Filter vault by #\(tag)")
    }
}

// MARK: - Wrapping Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        guard maxWidth > 0 else { return .zero }
        
        var totalHeight: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxHeightInRow: CGFloat = 0
        
        for view in subviews {
            let viewSize = view.sizeThatFits(.unspecified)
            if currentX + viewSize.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            maxHeightInRow = max(maxHeightInRow, viewSize.height)
            currentX += viewSize.width + spacing
        }
        totalHeight = currentY + maxHeightInRow
        return CGSize(width: maxWidth, height: totalHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var maxHeightInRow: CGFloat = 0
        
        for view in subviews {
            let viewSize = view.sizeThatFits(.unspecified)
            if currentX + viewSize.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += maxHeightInRow + spacing
                maxHeightInRow = 0
            }
            view.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            maxHeightInRow = max(maxHeightInRow, viewSize.height)
            currentX += viewSize.width + spacing
        }
    }
}

// MARK: - Markdown HTML Renderer

public enum MarkdownHTMLRenderer {
    
    public static func renderHTML(markdown: String, theme: TerminalTheme, contentWidth: Double) -> String {
        let (frontmatter, bodyMarkdown) = FrontmatterParser.parse(markdown)
        let doc = MarkdownPreviewView.parseDocument(frontmatter != nil ? bodyMarkdown : markdown)
        
        let css = generateCSS(theme: theme, contentWidth: contentWidth)
        let frontmatterHTML = renderFrontmatterHTML(frontmatter)
        let bodyHTML = renderBodyHTML(blocks: doc.blocks, footnotes: doc.footnotes)
        
        let mermaidScriptTag: String
        if let scriptURL = MermaidScriptProvider.getScriptURL() {
            mermaidScriptTag = "<script src=\"\(scriptURL.absoluteString)\"></script>"
        } else {
            mermaidScriptTag = "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>"
        }
        
        let mermaidTheme = theme.isDark ? "dark" : "default"
        
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Markdown Preview</title>
          <style id="theme-styles">
          \(css)
          </style>
          \(mermaidScriptTag)
        </head>
        <body>
          <div id="markdown-root">
            \(frontmatterHTML)
            \(bodyHTML)
          </div>
          <script>
            // Code block copy button handler
            function copyCode(button) {
              const container = button.closest('.code-block-container');
              if (!container) return;
              const code = container.querySelector('code');
              if (!code) return;
              navigator.clipboard.writeText(code.innerText).then(() => {
                const span = button.querySelector('span');
                const origText = span ? span.innerText : button.innerText;
                if (span) span.innerText = 'Copied!'; else button.innerText = 'Copied!';
                button.classList.add('copied');
                setTimeout(() => {
                  if (span) span.innerText = origText; else button.innerText = origText;
                  button.classList.remove('copied');
                }, 2000);
              }).catch(() => {});
            }

            // Tag pill click bridge
            function handleTagClick(tag) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tagHandler) {
                window.webkit.messageHandlers.tagHandler.postMessage(tag);
              }
            }

            // Document live update without scroll jumping
            window.updateDocument = function(newHTML) {
              try {
                const parser = new DOMParser();
                const newDoc = parser.parseFromString(newHTML, 'text/html');
                const newRoot = newDoc.getElementById('markdown-root');
                const currentRoot = document.getElementById('markdown-root');
                if (newRoot && currentRoot) {
                  currentRoot.innerHTML = newRoot.innerHTML;
                }
                const newStyle = newDoc.getElementById('theme-styles');
                const currentStyle = document.getElementById('theme-styles');
                if (newStyle && currentStyle && currentStyle.innerHTML !== newStyle.innerHTML) {
                  currentStyle.innerHTML = newStyle.innerHTML;
                }
                if (window.mermaid) {
                  try {
                    window.mermaid.run({ querySelector: '.mermaid' });
                  } catch (e) {}
                }
              } catch (err) {}
            };

            // Initialize Mermaid diagrams
            if (window.mermaid) {
              try {
                mermaid.initialize({
                  startOnLoad: true,
                  theme: '\(mermaidTheme)',
                  securityLevel: 'loose'
                });
              } catch (e) {}
            }
          </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Body HTML Generation
    
    public static func renderBodyHTML(blocks: [MarkdownPreviewView.MarkdownBlock], footnotes: [MarkdownPreviewView.FootnoteItem]) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .h1(let text):
                out += "<h1 id=\"\(slugify(text))\">\(renderInline(text))</h1>\n"
            case .h2(let text):
                out += "<h2 id=\"\(slugify(text))\">\(renderInline(text))</h2>\n"
            case .h3(let text):
                out += "<h3 id=\"\(slugify(text))\">\(renderInline(text))</h3>\n"
            case .h4(let text):
                out += "<h4 id=\"\(slugify(text))\">\(renderInline(text))</h4>\n"
            case .h5(let text):
                out += "<h5 id=\"\(slugify(text))\">\(renderInline(text))</h5>\n"
            case .h6(let text):
                out += "<h6 id=\"\(slugify(text))\">\(renderInline(text))</h6>\n"
            case .alert(let type, let text):
                out += renderAlertHTML(type: type, text: text) + "\n"
            case .codeBlock(let lang, let code):
                out += renderCodeBlockHTML(lang: lang, code: code) + "\n"
            case .mermaidDiagram(let code):
                out += renderMermaidHTML(code: code) + "\n"
            case .blockquote(let text):
                out += "<blockquote><p>\(renderInline(text))</p></blockquote>\n"
            case .taskItem(let done, let text):
                let checkedAttr = done ? "checked" : ""
                let doneClass = done ? "task-done" : ""
                out += """
                <div class="task-list-item">
                  <input type="checkbox" class="task-checkbox" \(checkedAttr) disabled />
                  <span class="\(doneClass)">\(renderInline(text))</span>
                </div>\n
                """
            case .listItem(let ordered, let number, let text, let indent):
                let bullet = ordered ? "\(number)." : "•"
                let padding = indent * 16
                out += """
                <div class="list-item" style="padding-left: \(padding)px;">
                  <span class="list-bullet">\(bullet)</span>
                  <span class="list-content">\(renderInline(text))</span>
                </div>\n
                """
            case .table(let headers, let alignments, let rows):
                out += renderTableHTML(headers: headers, alignments: alignments, rows: rows) + "\n"
            case .horizontalRule:
                out += "<hr class=\"markdown-hr\" />\n"
            case .paragraph(let text):
                out += "<p>\(renderInline(text))</p>\n"
            }
        }
        
        if !footnotes.isEmpty {
            out += "<div class=\"footnotes-section\">\n"
            out += "<hr class=\"markdown-hr\" />\n"
            out += "<h4 class=\"footnotes-title\">Footnotes</h4>\n"
            out += "<ol class=\"footnotes-list\">\n"
            for fn in footnotes {
                out += "<li id=\"fn-\(escapeHTML(fn.id))\">"
                out += "<span>\(renderInline(fn.text))</span> "
                out += "<a href=\"#fnref-\(escapeHTML(fn.id))\" class=\"footnote-backref\" title=\"Jump back to reference\">↩</a>"
                out += "</li>\n"
            }
            out += "</ol>\n</div>\n"
        }
        
        return out
    }
    
    // MARK: - Frontmatter Card HTML
    
    public static func renderFrontmatterHTML(_ frontmatter: ParsedFrontmatter?) -> String {
        guard let fm = frontmatter, !fm.isEmpty else { return "" }
        var out = "<details class=\"frontmatter-card\" open>\n"
        out += "<summary class=\"frontmatter-header\">\n"
        out += "<span class=\"frontmatter-title\">Properties</span>\n"
        out += "<span class=\"frontmatter-badge\">\(fm.properties.count)</span>\n"
        if !fm.tags.isEmpty {
            out += "<span class=\"frontmatter-tags-count\"># \(fm.tags.count)</span>\n"
        }
        out += "</summary>\n"
        out += "<div class=\"frontmatter-table\">\n"
        for prop in fm.properties {
            out += "<div class=\"frontmatter-row\">\n"
            out += "<div class=\"frontmatter-key\">\(escapeHTML(prop.key))</div>\n"
            out += "<div class=\"frontmatter-val\">\n"
            if prop.isTags && !prop.tags.isEmpty {
                for tag in prop.tags {
                    out += "<a href=\"brainmd://tag/\(tag)\" class=\"tag-pill\" onclick=\"handleTagClick('\(tag)'); return false;\"><span class=\"tag-hash\">#</span>\(escapeHTML(tag))</a>\n"
                }
            } else if prop.value.hasPrefix("http://") || prop.value.hasPrefix("https://") {
                out += "<a href=\"\(escapeHTML(prop.value))\" class=\"markdown-link\" target=\"_blank\">\(escapeHTML(prop.value))</a>\n"
            } else {
                let displayVal = FrontmatterParser.stripQuotes(prop.value)
                out += "<span>\(escapeHTML(displayVal))</span>\n"
            }
            out += "</div>\n</div>\n"
        }
        out += "</div>\n</details>\n"
        return out
    }
    
    // MARK: - Component Renderers
    
    public static func renderTableHTML(headers: [String], alignments: [TextAlignment], rows: [[String]]) -> String {
        var out = "<div class=\"table-container\"><table class=\"markdown-table\">\n"
        if !headers.isEmpty {
            out += "<thead>\n<tr>\n"
            for (idx, h) in headers.enumerated() {
                let align = idx < alignments.count ? alignments[idx] : .leading
                let alignStr = align == .center ? "center" : (align == .trailing ? "right" : "left")
                out += "<th style=\"text-align: \(alignStr);\">\(renderInline(h))</th>\n"
            }
            out += "</tr>\n</thead>\n"
        }
        if !rows.isEmpty {
            out += "<tbody>\n"
            for row in rows {
                out += "<tr>\n"
                for (idx, cell) in row.enumerated() {
                    let align = idx < alignments.count ? alignments[idx] : .leading
                    let alignStr = align == .center ? "center" : (align == .trailing ? "right" : "left")
                    out += "<td style=\"text-align: \(alignStr);\">\(renderInline(cell))</td>\n"
                }
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        out += "</table></div>"
        return out
    }
    
    public static func renderCodeBlockHTML(lang: String, code: String) -> String {
        let cleanLang = lang.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLang = cleanLang.isEmpty ? "code" : cleanLang
        let syntaxLang = SyntaxLanguage.from(identifier: cleanLang)
        let highlighted = SyntaxHighlighter.highlightToHTML(code: code, language: syntaxLang)
        
        return """
        <div class="code-block-container">
          <div class="code-block-header">
            <div class="code-header-left">
              <div class="window-dots" aria-hidden="true">
                <span class="window-dot dot-red"></span>
                <span class="window-dot dot-yellow"></span>
                <span class="window-dot dot-green"></span>
              </div>
              <span class="code-lang">\(escapeHTML(displayLang))</span>
            </div>
            <button class="copy-button" onclick="copyCode(this)" title="Copy to clipboard">
              <svg class="copy-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
              </svg>
              <span>Copy</span>
            </button>
          </div>
          <pre class="code-block-pre"><code class="language-\(escapeHTML(cleanLang))">\(highlighted)</code></pre>
        </div>
        """
    }
    
    public static func renderMermaidHTML(code: String) -> String {
        let escapedCode = escapeHTML(code)
        return """
        <div class="mermaid-container">
          <div class="mermaid">\(escapedCode)</div>
        </div>
        """
    }
    
    public static func renderAlertHTML(type: AlertType, text: String) -> String {
        let iconSVG = alertIconSVG(for: type)
        return """
        <div class="markdown-alert markdown-alert-\(type.rawValue.lowercased())">
          <div class="markdown-alert-title">
            <span class="markdown-alert-icon">\(iconSVG)</span>
            <span>\(type.title)</span>
          </div>
          <div class="markdown-alert-content">\(renderInline(text))</div>
        </div>
        """
    }
    
    private static func alertIconSVG(for type: AlertType) -> String {
        switch type {
        case .note:
            return "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z\"/></svg>"
        case .tip:
            return "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.21c-.04-.282-.18-.57-.393-.878a16.27 16.27 0 0 0-.582-.733l-.216-.255C3.171 7.734 2.5 6.822 2.5 5.25 2.5 2.31 4.887 0 8 0s5.5 2.31 5.5 5.25c0 1.572-.671 2.484-1.317 3.254l-.216.255c-.177.209-.367.434-.582.733-.213.308-.353.596-.393.878a.75.75 0 0 1-1.484-.21c.084-.594.337-1.079.621-1.49.203-.292.45-.584.673-.848l.214-.253c.56-.679.984-1.32.984-2.304 0-2.06-1.637-3.75-4-3.75ZM6 12a1 1 0 0 1 1-1h2a1 1 0 0 1 1 1v1a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-1Z\"/></svg>"
        case .important:
            return "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM7.25 4.75v4.5a.75.75 0 0 0 1.5 0v-4.5a.75.75 0 0 0-1.5 0ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z\"/></svg>"
        case .warning:
            return "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z\"/></svg>"
        case .caution:
            return "<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"currentColor\"><path d=\"M4.47.04c.37-.04.74.08 1.03.32L15.64 10.5c.34.29.54.71.54 1.16v2.59c0 .97-.78 1.75-1.75 1.75H1.57C.6 16 0 15.22 0 14.25v-2.59c0-.45.2-.87.54-1.16L10.68.36c.29-.24.66-.36 1.03-.32ZM8 4.75a.75.75 0 0 0-.75.75v3.5a.75.75 0 0 0 1.5 0v-3.5A.75.75 0 0 0 8 4.75ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z\"/></svg>"
        }
    }
    
    // MARK: - Inline Markdown Formatting
    
    public static func renderInline(_ text: String) -> String {
        var str = text
        str = str.replacingOccurrences(of: "<del>", with: "~~")
        str = str.replacingOccurrences(of: "</del>", with: "~~")
        str = str.replacingOccurrences(of: "<s>", with: "~~")
        str = str.replacingOccurrences(of: "</s>", with: "~~")
        
        var placeholders: [String: String] = [:]
        var pCounter = 0
        
        // Step 1: Code spans `code`
        if let codeSpanRegex = try? NSRegularExpression(pattern: "`([^`]+)`") {
            let matches = codeSpanRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let codeR = Range(match.range(at: 1), in: str) {
                    let codeText = String(str[codeR])
                    let key = "@@CODE_SPAN_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<code>\(escapeHTML(codeText))</code>"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 2: Images ![alt](url)
        if let imgRegex = try? NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\(([^\\)]+)\\)") {
            let matches = imgRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let altR = Range(match.range(at: 1), in: str),
                   let urlR = Range(match.range(at: 2), in: str) {
                    let alt = String(str[altR])
                    let url = String(str[urlR]).trimmingCharacters(in: .whitespaces)
                    let key = "@@IMG_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(alt))\" style=\"max-width: 100%; height: auto; border-radius: 4px;\" />"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 3: Links [text](url)
        if let linkRegex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)") {
            let matches = linkRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let textR = Range(match.range(at: 1), in: str),
                   let urlR = Range(match.range(at: 2), in: str) {
                    let linkText = String(str[textR])
                    let url = String(str[urlR]).trimmingCharacters(in: .whitespaces)
                    let key = "@@LINK_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<a href=\"\(escapeHTML(url))\" class=\"markdown-link\">\(escapeHTML(linkText))</a>"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 4: Footnote references [^id]
        if let fnRefRegex = try? NSRegularExpression(pattern: "\\[\\^([^\\]]+)\\]") {
            let matches = fnRefRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let idR = Range(match.range(at: 1), in: str) {
                    let fnId = String(str[idR])
                    let key = "@@FNREF_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<sup id=\"fnref-\(escapeHTML(fnId))\"><a href=\"#fn-\(escapeHTML(fnId))\" class=\"footnote-ref\">[\(escapeHTML(fnId))]</a></sup>"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 5: HTML escape remaining text
        str = escapeHTML(str)
        
        // Step 6: Hex color badges e.g. #0969da
        if let hexRegex = try? NSRegularExpression(pattern: "(?<=^|[\\s\\(\\)\\[\\]\\{\\},;:])#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b") {
            let matches = hexRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let hexR = Range(match.range(at: 1), in: str) {
                    let hexDigits = String(str[hexR])
                    let key = "@@HEX_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<span class=\"hex-badge\"><span class=\"hex-swatch\" style=\"background-color: #\(hexDigits);\"></span>#\(hexDigits)</span>"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 7: Hashtags #tag
        if let tagRegex = try? NSRegularExpression(pattern: "(?<=^|[\\s\\(\\)\\[\\]])#([a-zA-Z][a-zA-Z0-9_\\-]*)\\b") {
            let matches = tagRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let r = Range(match.range, in: str),
                   let tagR = Range(match.range(at: 1), in: str) {
                    let tagName = String(str[tagR])
                    let key = "@@TAG_\(pCounter)@@"
                    pCounter += 1
                    placeholders[key] = "<a href=\"brainmd://tag/\(tagName)\" class=\"tag-pill\" onclick=\"handleTagClick('\(tagName)'); return false;\"><span class=\"tag-hash\">#</span>\(tagName)</a>"
                    str.replaceSubrange(r, with: key)
                }
            }
        }
        
        // Step 8: Bold, Italic, Strikethrough
        if let boldRegex1 = try? NSRegularExpression(pattern: "\\*\\*([^*]+)\\*\\*") {
            str = boldRegex1.stringByReplacingMatches(in: str, range: NSRange(location: 0, length: str.utf16.count), withTemplate: "<strong>$1</strong>")
        }
        if let boldRegex2 = try? NSRegularExpression(pattern: "__([^_]+)__") {
            str = boldRegex2.stringByReplacingMatches(in: str, range: NSRange(location: 0, length: str.utf16.count), withTemplate: "<strong>$1</strong>")
        }
        if let italicRegex1 = try? NSRegularExpression(pattern: "\\*([^*]+)\\*") {
            str = italicRegex1.stringByReplacingMatches(in: str, range: NSRange(location: 0, length: str.utf16.count), withTemplate: "<em>$1</em>")
        }
        if let italicRegex2 = try? NSRegularExpression(pattern: "(?<![a-zA-Z0-9])_([^_]+)_(?![a-zA-Z0-9])") {
            str = italicRegex2.stringByReplacingMatches(in: str, range: NSRange(location: 0, length: str.utf16.count), withTemplate: "<em>$1</em>")
        }
        if let strikeRegex = try? NSRegularExpression(pattern: "~~([^~]+)~~") {
            str = strikeRegex.stringByReplacingMatches(in: str, range: NSRange(location: 0, length: str.utf16.count), withTemplate: "<del>$1</del>")
        }
        
        // Step 9: Restore placeholders
        for (key, val) in placeholders {
            str = str.replacingOccurrences(of: key, with: val)
        }
        
        return str
    }
    
    // MARK: - CSS Styling
    
    public static func generateCSS(theme: TerminalTheme, contentWidth: Double) -> String {
        let isDark = theme.isDark
        let palette = theme.palette
        let borderColor = isDark ? "rgba(255, 255, 255, 0.12)" : "rgba(0, 0, 0, 0.12)"
        
        // Code block container styling
        let codeBg = isDark ? "#161b22" : "#f6f8fa"
        let headerCodeBg = isDark ? "#0d1117" : "#eaeef2"
        let codeBorder = isDark ? "rgba(255, 255, 255, 0.14)" : "rgba(0, 0, 0, 0.12)"
        let inlineCodeBg = isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.05)"
        let inlineCodeColor = isDark ? "#79c0ff" : "#0969da"
        let codeLangBg = isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.06)"
        
        // Syntax Token Colors mapped to Theme ANSI Palette with vibrant fallbacks
        let synKw = palette.indices.contains(1) ? palette[1] : (isDark ? "#ff7b72" : "#cf222e")
        let synStr = palette.indices.contains(2) ? palette[2] : (isDark ? "#7ee787" : "#116329")
        let synNum = palette.indices.contains(11) ? palette[11] : (palette.indices.contains(3) ? palette[3] : (isDark ? "#79c0ff" : "#0550ae"))
        let synFn = palette.indices.contains(4) ? palette[4] : (isDark ? "#58a6ff" : "#0969da")
        let synType = palette.indices.contains(5) ? palette[5] : (isDark ? "#bc8cff" : "#8250df")
        let synAttr = palette.indices.contains(6) ? palette[6] : (isDark ? "#39c5cf" : "#1b7c83")
        let synComment = palette.indices.contains(8) ? palette[8] : (isDark ? "#8b949e" : "#6e7781")
        let synBool = palette.indices.contains(9) ? palette[9] : synKw
        let synTag = palette.indices.contains(14) ? palette[14] : (palette.indices.contains(6) ? palette[6] : (isDark ? "#56d4dd" : "#0550ae"))
        let synKey = palette.indices.contains(12) ? palette[12] : synFn
        
        let tableHeaderBg = isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(0, 0, 0, 0.05)"
        let tableStripeBg = isDark ? "rgba(255, 255, 255, 0.03)" : "rgba(0, 0, 0, 0.02)"
        
        return """
        :root {
          --bg-color: \(theme.backgroundHex);
          --text-color: \(theme.foregroundHex);
          --selection-bg: \(theme.selectionBackgroundHex);
          --accent-color: \(theme.cursorColorHex);
          --content-max-width: \(contentWidth)px;
          --border-color: \(borderColor);
          --code-bg: \(codeBg);
          --header-code-bg: \(headerCodeBg);
          --code-border: \(codeBorder);
          --inline-code-bg: \(inlineCodeBg);
          --inline-code-color: \(inlineCodeColor);
          --code-lang-bg: \(codeLangBg);
          
          /* Syntax Token Colors */
          --syn-kw: \(synKw);
          --syn-str: \(synStr);
          --syn-num: \(synNum);
          --syn-fn: \(synFn);
          --syn-type: \(synType);
          --syn-attr: \(synAttr);
          --syn-comment: \(synComment);
          --syn-bool: \(synBool);
          --syn-tag: \(synTag);
          --syn-key: \(synKey);

          --table-header-bg: \(tableHeaderBg);
          --table-stripe-bg: \(tableStripeBg);
        }

        * {
          box-sizing: border-box;
          -webkit-user-select: text;
          user-select: text;
        }

        html, body {
          background-color: var(--bg-color);
          color: var(--text-color);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          font-size: 14px;
          line-height: 1.6;
          margin: 0;
          padding: 0;
          width: 100%;
          min-height: 100%;
          overflow-x: hidden;
          overflow-y: auto;
          -webkit-font-smoothing: antialiased;
        }

        ::selection {
          background-color: var(--selection-bg);
          color: inherit;
        }

        #markdown-root {
          max-width: var(--content-max-width);
          margin: 0 auto;
          padding: 24px 32px 64px 32px;
        }

        /* Headings */
        h1, h2, h3, h4, h5, h6 {
          font-weight: 600;
          line-height: 1.25;
          margin-top: 24px;
          margin-bottom: 12px;
          color: var(--text-color);
        }
        h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border-color); }
        h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border-color); }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; opacity: 0.85; }
        h6 { font-size: 0.85em; opacity: 0.7; }

        p {
          margin-top: 0;
          margin-bottom: 14px;
        }

        a {
          color: var(--accent-color);
          text-decoration: underline;
          text-underline-offset: 2px;
        }
        a:hover {
          opacity: 0.85;
        }

        /* Code & Code Blocks */
        code {
          font-family: "SF Mono", Menlo, Monaco, Consolas, "Courier New", monospace;
          font-size: 0.9em;
          background-color: var(--inline-code-bg);
          color: var(--inline-code-color);
          padding: 0.18em 0.45em;
          border-radius: 4px;
          border: 1px solid var(--border-color);
        }

        pre code {
          background-color: transparent;
          color: var(--text-color);
          padding: 0;
          border: none;
          font-size: 13px;
          line-height: 1.55;
        }

        .code-block-container {
          margin: 20px 0;
          border: 1px solid var(--code-border);
          border-radius: 8px;
          overflow: hidden;
          background-color: var(--code-bg);
          box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
        }

        .code-block-header {
          display: flex;
          justify-content: space-between;
          align-items: center;
          padding: 8px 14px;
          background-color: var(--header-code-bg);
          border-bottom: 1px solid var(--code-border);
          -webkit-user-select: none;
          user-select: none;
        }

        .code-header-left {
          display: flex;
          align-items: center;
          gap: 10px;
        }

        .window-dots {
          display: flex;
          align-items: center;
          gap: 5px;
        }

        .window-dot {
          width: 9px;
          height: 9px;
          border-radius: 50%;
          display: inline-block;
        }
        .dot-red { background-color: #ff5f56; }
        .dot-yellow { background-color: #ffbd2e; }
        .dot-green { background-color: #27c93f; }

        .code-lang {
          font-family: "SF Mono", Menlo, monospace;
          font-size: 10.5px;
          font-weight: 700;
          text-transform: uppercase;
          color: var(--accent-color);
          background-color: var(--code-lang-bg);
          padding: 2px 7px;
          border-radius: 4px;
          letter-spacing: 0.6px;
        }

        .copy-button {
          display: inline-flex;
          align-items: center;
          gap: 4px;
          background: transparent;
          border: 1px solid var(--code-border);
          color: var(--text-color);
          border-radius: 5px;
          padding: 3px 8px;
          font-size: 11px;
          font-weight: 500;
          cursor: pointer;
          transition: all 0.15s ease;
          -webkit-user-select: none;
          user-select: none;
          opacity: 0.85;
        }
        .copy-button:hover {
          opacity: 1;
          background: var(--code-lang-bg);
          border-color: var(--accent-color);
        }
        .copy-button.copied {
          color: #2ea043;
          border-color: #2ea043;
          opacity: 1;
        }
        .copy-icon {
          width: 12px;
          height: 12px;
        }

        pre.code-block-pre {
          margin: 0;
          padding: 14px 16px;
          overflow-x: auto;
        }

        /* Syntax Token Highlighting */
        .tok-kw { color: var(--syn-kw); font-weight: 600; }
        .tok-str { color: var(--syn-str); }
        .tok-num { color: var(--syn-num); }
        .tok-fn { color: var(--syn-fn); }
        .tok-type { color: var(--syn-type); font-weight: 600; }
        .tok-attr { color: var(--syn-attr); }
        .tok-comment { color: var(--syn-comment); font-style: italic; opacity: 0.85; }
        .tok-bool { color: var(--syn-bool); font-weight: 600; }
        .tok-tag { color: var(--syn-tag); font-weight: 600; }
        .tok-key { color: var(--syn-key); font-weight: 600; }

        /* Tables */
        .table-container {
          width: 100%;
          overflow-x: auto;
          margin: 16px 0;
        }
        table.markdown-table {
          width: 100%;
          border-collapse: collapse;
          font-size: 13.5px;
        }
        table.markdown-table th, table.markdown-table td {
          border: 1px solid var(--border-color);
          padding: 8px 12px;
        }
        table.markdown-table th {
          background-color: var(--table-header-bg);
          font-weight: 600;
        }
        table.markdown-table tr:nth-child(even) {
          background-color: var(--table-stripe-bg);
        }

        /* Blockquotes */
        blockquote {
          margin: 16px 0;
          padding: 0 16px;
          color: var(--text-color);
          opacity: 0.85;
          border-left: 4px solid var(--border-color);
        }

        /* GFM Alerts */
        .markdown-alert {
          padding: 10px 14px;
          margin: 16px 0;
          border-left: 4px solid;
          border-radius: 0 6px 6px 0;
        }
        .markdown-alert-note { border-left-color: #0969da; background-color: rgba(9, 105, 218, 0.08); }
        .markdown-alert-note .markdown-alert-title { color: #0969da; }
        .markdown-alert-tip { border-left-color: #1a7f37; background-color: rgba(26, 127, 55, 0.08); }
        .markdown-alert-tip .markdown-alert-title { color: #1a7f37; }
        .markdown-alert-important { border-left-color: #8250df; background-color: rgba(130, 80, 223, 0.08); }
        .markdown-alert-important .markdown-alert-title { color: #8250df; }
        .markdown-alert-warning { border-left-color: #9a6700; background-color: rgba(154, 103, 0, 0.08); }
        .markdown-alert-warning .markdown-alert-title { color: #9a6700; }
        .markdown-alert-caution { border-left-color: #cf222e; background-color: rgba(207, 34, 46, 0.08); }
        .markdown-alert-caution .markdown-alert-title { color: #cf222e; }

        .markdown-alert-title {
          display: flex;
          align-items: center;
          gap: 6px;
          font-weight: 600;
          font-size: 13px;
          margin-bottom: 4px;
        }
        .markdown-alert-icon svg {
          width: 14px;
          height: 14px;
          display: block;
        }
        .markdown-alert-content {
          font-size: 13.5px;
        }

        /* Task list items */
        .task-list-item {
          display: flex;
          align-items: flex-start;
          gap: 8px;
          margin: 4px 0;
        }
        .task-checkbox {
          margin-top: 3px;
        }
        .task-done {
          text-decoration: line-through;
          opacity: 0.65;
        }

        /* List Items */
        .list-item {
          display: flex;
          align-items: flex-start;
          gap: 8px;
          margin: 3px 0;
        }
        .list-bullet {
          font-weight: 600;
          min-width: 16px;
          text-align: right;
          opacity: 0.75;
        }

        /* Horizontal Rule */
        hr.markdown-hr {
          border: none;
          height: 1px;
          background-color: var(--border-color);
          margin: 24px 0;
        }

        /* Frontmatter */
        .frontmatter-card {
          border: 1px solid var(--border-color);
          border-radius: 8px;
          margin-bottom: 24px;
          background-color: var(--code-bg);
          overflow: hidden;
        }
        .frontmatter-header {
          padding: 8px 14px;
          cursor: pointer;
          display: flex;
          align-items: center;
          gap: 8px;
          font-size: 12px;
          font-weight: 600;
          background-color: var(--header-code-bg);
          -webkit-user-select: none;
          user-select: none;
        }
        .frontmatter-badge {
          font-size: 10px;
          background: var(--border-color);
          padding: 1px 6px;
          border-radius: 10px;
        }
        .frontmatter-tags-count {
          font-size: 11px;
          color: var(--accent-color);
          font-weight: 600;
        }
        .frontmatter-table {
          padding: 10px 14px;
          font-size: 12px;
        }
        .frontmatter-row {
          display: flex;
          align-items: baseline;
          padding: 4px 0;
        }
        .frontmatter-key {
          width: 120px;
          flex-shrink: 0;
          font-family: "SF Mono", Menlo, monospace;
          opacity: 0.75;
        }

        /* Tags & Hex badges */
        .tag-pill {
          display: inline-flex;
          align-items: center;
          gap: 2px;
          background: rgba(128, 128, 128, 0.15);
          border: 1px solid var(--border-color);
          color: var(--text-color);
          text-decoration: none;
          padding: 1px 7px;
          border-radius: 12px;
          font-size: 11px;
          font-weight: 500;
          margin: 0 2px;
          cursor: pointer;
        }
        .tag-pill:hover {
          border-color: var(--accent-color);
        }
        .tag-hash {
          color: var(--accent-color);
          font-weight: 700;
        }

        .hex-badge {
          display: inline-flex;
          align-items: center;
          gap: 5px;
          background: var(--code-bg);
          border: 1px solid var(--border-color);
          padding: 1px 6px;
          border-radius: 4px;
          font-family: "SF Mono", Menlo, monospace;
          font-size: 11.5px;
        }
        .hex-swatch {
          width: 10px;
          height: 10px;
          border-radius: 2px;
          border: 1px solid rgba(128, 128, 128, 0.4);
          display: inline-block;
        }

        /* Footnotes */
        .footnotes-section {
          margin-top: 32px;
          font-size: 12.5px;
          opacity: 0.85;
        }
        .footnotes-title {
          font-size: 13px;
          margin-bottom: 8px;
        }
        .footnotes-list {
          padding-left: 20px;
        }
        .footnote-backref {
          text-decoration: none;
          margin-left: 4px;
        }

        /* Mermaid */
        .mermaid-container {
          display: flex;
          justify-content: center;
          margin: 16px 0;
          overflow-x: auto;
        }
        .mermaid {
          text-align: center;
        }
        """
    }
    
    // MARK: - Utilities
    
    public static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    private static func slugify(_ text: String) -> String {
        let clean = text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined()
        return clean.isEmpty ? "heading" : clean
    }
}

// MARK: - Markdown Web View

public struct MarkdownWebView: NSViewRepresentable {
    public let html: String
    public var onTagSelected: ((String) -> Void)?
    
    public init(html: String, onTagSelected: ((String) -> Void)? = nil) {
        self.html = html
        self.onTagSelected = onTagSelected
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tagHandler")
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        let baseURL = MermaidScriptProvider.getScriptURL()?.deletingLastPathComponent() ?? Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.lastHTML = html
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        
        if context.coordinator.isPageLoaded {
            if let data = try? JSONSerialization.data(withJSONObject: [html]),
               let jsonString = String(data: data, encoding: .utf8) {
                let js = "if (window.updateDocument) { window.updateDocument(\(jsonString)[0]); }"
                nsView.evaluateJavaScript(js) { [weak nsView] _, error in
                    if error != nil {
                        let baseURL = MermaidScriptProvider.getScriptURL()?.deletingLastPathComponent() ?? Bundle.main.resourceURL
                        nsView?.loadHTMLString(self.html, baseURL: baseURL)
                    }
                }
            } else {
                let baseURL = MermaidScriptProvider.getScriptURL()?.deletingLastPathComponent() ?? Bundle.main.resourceURL
                nsView.loadHTMLString(html, baseURL: baseURL)
            }
        } else {
            let baseURL = MermaidScriptProvider.getScriptURL()?.deletingLastPathComponent() ?? Bundle.main.resourceURL
            nsView.loadHTMLString(html, baseURL: baseURL)
        }
    }
    
    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "tagHandler")
        nsView.navigationDelegate = nil
        nsView.stopLoading()
    }
    
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebView
        var lastHTML: String?
        var isPageLoaded = false
        
        init(_ parent: MarkdownWebView) {
            self.parent = parent
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
        }
        
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if url.scheme == "brainmd" {
                    if url.host == "tag" {
                        let tag = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        parent.onTagSelected?(tag)
                    }
                    decisionHandler(.cancel)
                    return
                } else if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                } else if url.scheme == "file" || url.scheme == "about" {
                    decisionHandler(.allow)
                    return
                }
            }
            decisionHandler(.allow)
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "tagHandler", let tag = message.body as? String {
                parent.onTagSelected?(tag)
            }
        }
    }
}


