//
//  MarkdownPreviewView.swift
//  brain-md
//

import SwiftUI

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
    let markdown: String
    var onTagSelected: ((String) -> Void)?
    
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
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 0) {
                    ForEach(headers.indices, id: \.self) { idx in
                        let align = idx < alignments.count ? alignments[idx] : .leading
                        Text(parseAttributedString(headers[idx]))
                            .font(.system(size: 13, weight: .bold))
                            .frame(minWidth: 100, alignment: frameAlignment(for: align))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .border(Color.secondary.opacity(0.15), width: 0.5)
                    }
                }
                
                // Table Rows
                ForEach(rows.indices, id: \.self) { rIdx in
                    let row = rows[rIdx]
                    HStack(spacing: 0) {
                        ForEach(headers.indices, id: \.self) { cIdx in
                            let align = cIdx < alignments.count ? alignments[cIdx] : .leading
                            let cellText = cIdx < row.count ? row[cIdx] : ""
                            Text(parseAttributedString(cellText))
                                .font(.system(size: 13))
                                .frame(minWidth: 100, alignment: frameAlignment(for: align))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(rIdx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                                .border(Color.secondary.opacity(0.15), width: 0.5)
                        }
                    }
                }
            }
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

