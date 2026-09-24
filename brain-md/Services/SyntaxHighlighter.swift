//
//  SyntaxHighlighter.swift
//  brain-md
//

import SwiftUI
import AppKit

// MARK: - Syntax Language

public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift
    case python = "py"
    case javascript = "js"
    case typescript = "ts"
    case json
    case bash = "sh"
    case sql
    case html
    case css
    case yaml = "yml"
    case markdown = "md"
    case mermaid
    case plain
    
    public static func from(identifier: String) -> SyntaxLanguage {
        let clean = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch clean {
        case "swift": return .swift
        case "python", "py": return .python
        case "javascript", "js": return .javascript
        case "typescript", "ts": return .typescript
        case "json": return .json
        case "bash", "sh", "zsh", "shell": return .bash
        case "sql": return .sql
        case "html", "xml", "svg": return .html
        case "css", "scss", "sass": return .css
        case "yaml", "yml": return .yaml
        case "markdown", "md": return .markdown
        case "mermaid": return .mermaid
        default: return .plain
        }
    }
    
    public var displayName: String {
        switch self {
        case .swift: return "SWIFT"
        case .python: return "PYTHON"
        case .javascript: return "JAVASCRIPT"
        case .typescript: return "TYPESCRIPT"
        case .json: return "JSON"
        case .bash: return "BASH"
        case .sql: return "SQL"
        case .html: return "HTML"
        case .css: return "CSS"
        case .yaml: return "YAML"
        case .markdown: return "MARKDOWN"
        case .mermaid: return "MERMAID"
        case .plain: return "TEXT"
        }
    }
}

// MARK: - Color Hex Initializer

public extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let length = hexSanitized.count
        if length == 6 {
            let r = Double((rgb & 0xFF0000) >> 16) / 255.0
            let g = Double((rgb & 0x00FF00) >> 8) / 255.0
            let b = Double(rgb & 0x0000FF) / 255.0
            self.init(red: r, green: g, blue: b)
        } else if length == 3 {
            let r = Double((rgb & 0xF00) >> 8) / 15.0
            let g = Double((rgb & 0x0F0) >> 4) / 15.0
            let b = Double(rgb & 0x00F) / 15.0
            self.init(red: r, green: g, blue: b)
        } else {
            return nil
        }
    }
}

public extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let length = hexSanitized.count
        if length == 6 {
            let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
            let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
            let b = CGFloat(rgb & 0x0000FF) / 255.0
            self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
        } else if length == 3 {
            let r = CGFloat((rgb & 0xF00) >> 8) / 15.0
            let g = CGFloat((rgb & 0x0F0) >> 4) / 15.0
            let b = CGFloat(rgb & 0x00F) / 15.0
            self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
        } else {
            return nil
        }
    }
}

// MARK: - Syntax Themes (Dark & Light)

public struct SyntaxTheme: Sendable {
    public let name: String
    public let keyword: Color
    public let type: Color
    public let string: Color
    public let comment: Color
    public let number: Color
    public let attribute: Color
    public let boolean: Color
    public let function: Color
    public let plainText: Color
    public let background: Color
    public let headerBackground: Color
    public let border: Color
    
    public init(
        name: String,
        keyword: Color,
        type: Color,
        string: Color,
        comment: Color,
        number: Color,
        attribute: Color,
        boolean: Color,
        function: Color,
        plainText: Color,
        background: Color,
        headerBackground: Color,
        border: Color
    ) {
        self.name = name
        self.keyword = keyword
        self.type = type
        self.string = string
        self.comment = comment
        self.number = number
        self.attribute = attribute
        self.boolean = boolean
        self.function = function
        self.plainText = plainText
        self.background = background
        self.headerBackground = headerBackground
        self.border = border
    }
    
    // Official GitHub Dark Theme (High Contrast, Bright Vibrant Tokens)
    public static let githubDark = SyntaxTheme(
        name: "GitHub Dark",
        keyword: Color(hex: "#ff7b72")!,      // Vibrant Coral (#ff7b72)
        type: Color(hex: "#ffa657")!,         // Warm Orange (#ffa657)
        string: Color(hex: "#a5d6ff")!,       // Bright Sky Blue (#a5d6ff)
        comment: Color(hex: "#8b949e")!,      // Slate Muted (#8b949e)
        number: Color(hex: "#79c0ff")!,       // Vivid Cyan (#79c0ff)
        attribute: Color(hex: "#d2a8ff")!,    // Purple Lavender (#d2a8ff)
        boolean: Color(hex: "#ff7b72")!,      // Coral (#ff7b72)
        function: Color(hex: "#d2a8ff")!,     // Purple Lavender (#d2a8ff)
        plainText: Color(hex: "#f0f6fc")!,    // High-Contrast Bright White (#f0f6fc)
        background: Color(hex: "#161b22")!,   // Elevated Dark (#161b22)
        headerBackground: Color(hex: "#0d1117")!, // Deep Header (#0d1117)
        border: Color(hex: "#30363d")!        // Border (#30363d)
    )
    
    // Dracula High-Contrast Dark Theme
    public static let dracula = SyntaxTheme(
        name: "Dracula",
        keyword: Color(hex: "#ff79c6")!,      // Hot Pink
        type: Color(hex: "#8be9fd")!,         // Cyan
        string: Color(hex: "#f1fa8c")!,       // Yellow
        comment: Color(hex: "#6272a4")!,      // Comment Blue-Grey
        number: Color(hex: "#bd93f9")!,       // Purple
        attribute: Color(hex: "#50fa7b")!,    // Green
        boolean: Color(hex: "#ff79c6")!,      // Hot Pink
        function: Color(hex: "#50fa7b")!,     // Green
        plainText: Color(hex: "#f8f8f2")!,    // Crisp Off-White
        background: Color(hex: "#282a36")!,   // Dracula Background
        headerBackground: Color(hex: "#21222c")!, // Header
        border: Color(hex: "#44475a")!        // Selection Border
    )
    
    // Monokai High-Contrast Dark Theme
    public static let monokai = SyntaxTheme(
        name: "Monokai",
        keyword: Color(hex: "#f92672")!,      // Monokai Pink
        type: Color(hex: "#66d9ef")!,         // Monokai Blue
        string: Color(hex: "#e6db74")!,       // Monokai Yellow
        comment: Color(hex: "#75715e")!,      // Monokai Grey
        number: Color(hex: "#ae81ff")!,       // Monokai Purple
        attribute: Color(hex: "#a6e22e")!,    // Monokai Green
        boolean: Color(hex: "#ae81ff")!,      // Purple
        function: Color(hex: "#a6e22e")!,     // Green
        plainText: Color(hex: "#f8f8f2")!,    // Off-white
        background: Color(hex: "#272822")!,   // Dark Olive/Charcoal
        headerBackground: Color(hex: "#1e1f1c")!, // Deep Header
        border: Color(hex: "#49483e")!        // Border
    )
    
    // Official GitHub Light Theme (Clean Crisp Contrast)
    public static let githubLight = SyntaxTheme(
        name: "GitHub Light",
        keyword: Color(hex: "#cf222e")!,      // GitHub Red
        type: Color(hex: "#953800")!,         // Burnt Orange
        string: Color(hex: "#0a3069")!,       // Deep Navy
        comment: Color(hex: "#6e7781")!,      // Muted Grey
        number: Color(hex: "#0550ae")!,       // Vivid Royal Blue
        attribute: Color(hex: "#8250df")!,    // Purple
        boolean: Color(hex: "#cf222e")!,      // Red
        function: Color(hex: "#8250df")!,     // Purple
        plainText: Color(hex: "#24292f")!,    // Slate Charcoal (#24292f)
        background: Color(hex: "#f6f8fa")!,   // GitHub Light Canvas
        headerBackground: Color(hex: "#eaeef2")!, // Light Header
        border: Color(hex: "#d0d7de")!        // Light Border
    )
    
    public static func theme(for colorScheme: ColorScheme) -> SyntaxTheme {
        ThemeManager.resolveTheme(for: colorScheme).toSyntaxTheme()
    }
}

// MARK: - High-Contrast Syntax Highlighter

public struct SyntaxHighlighter: Sendable {
    
    private static let swiftKeywords: Set<String> = [
        "actor", "associatedtype", "async", "await", "as", "break", "case", "catch", "class",
        "continue", "convenience", "default", "defer", "deinit", "do", "dynamic", "else", "enum",
        "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get",
        "guard", "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is",
        "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "optional",
        "override", "postfix", "prefix", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "set", "some", "static", "struct", "subscript", "super",
        "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var", "weak",
        "where", "while"
    ]
    
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
        "with", "yield"
    ]
    
    private static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "function",
        "if", "import", "in", "instanceof", "let", "new", "return", "super", "switch", "this",
        "throw", "try", "typeof", "var", "void", "while", "with", "yield", "interface", "type"
    ]
    
    private static let bashKeywords: Set<String> = [
        "export", "source", "alias", "if", "then", "else", "elif", "fi", "for", "in", "do",
        "done", "while", "case", "esac", "function", "return", "exit", "read", "local"
    ]
    
    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
        "create", "table", "drop", "alter", "add", "join", "inner", "left", "right", "outer",
        "group", "by", "order", "having", "limit", "offset", "union", "all", "and", "or",
        "not", "null", "is", "as", "in", "like", "between", "exists", "case", "when", "then",
        "end", "distinct", "primary", "key", "foreign", "references", "index"
    ]
    
    private static let mermaidKeywords: Set<String> = [
        "graph", "flowchart", "sequencediagram", "classdiagram", "statediagram",
        "erdiagram", "gantt", "pie", "gitgraph", "mindmap", "timeline",
        "quadrantchart", "subgraph", "end", "participant", "actor", "autonumber",
        "activate", "deactivate", "loop", "alt", "else", "opt", "par", "critical",
        "option", "break", "rect", "note", "over", "of", "title", "acctitle",
        "accdescr", "section", "click", "call", "link", "style", "classdef",
        "class", "direction", "tb", "td", "bt", "rl", "lr"
    ]
    
    private static let booleansAndLiterals: Set<String> = [
        "true", "false", "nil", "null", "none", "undefined", "nan"
    ]
    
    // MARK: - Pre-compiled Regex Singletons for High Performance
    
    private static let wordRegex = try! NSRegularExpression(pattern: "\\b[a-zA-Z_][a-zA-Z0-9_]*\\b")
    private static let funcRegex = try! NSRegularExpression(pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*(?=\\()")
    private static let numRegex = try! NSRegularExpression(pattern: "\\b(0x[0-9a-fA-F]+|0b[01]+|\\d+(\\.\\d+)?([eE][+-]?\\d+)?)\\b")
    private static let attrRegex = try! NSRegularExpression(pattern: "@[a-zA-Z_][a-zA-Z0-9_]*")
    private static let strRegex = try! NSRegularExpression(pattern: "(\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"|'[^'\\\\]*(?:\\\\.[^'\\\\]*)*'|`[^`\\\\]*(?:\\\\.[^`\\\\]*)*`)")
    private static let jsonKeyRegex = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s*:")
    private static let htmlTagRegex = try! NSRegularExpression(pattern: "</?[a-zA-Z0-9_\\-]+")
    private static let htmlAttrRegex = try! NSRegularExpression(pattern: "\\s([a-zA-Z0-9_\\-]+)=")
    
    // Comment Regexes
    private static let slashSlashCommentRegex = try! NSRegularExpression(pattern: "//.*$", options: [.anchorsMatchLines])
    private static let slashStarCommentRegex = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
    private static let hashCommentRegex = try! NSRegularExpression(pattern: "#.*$", options: [.anchorsMatchLines])
    private static let sqlDashCommentRegex = try! NSRegularExpression(pattern: "--.*$", options: [.anchorsMatchLines])
    private static let htmlCommentRegex = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->")
    private static let mermaidCommentRegex = try! NSRegularExpression(pattern: "%%.*$", options: [.anchorsMatchLines])
    
    // Cache box for AttributedString
    private final class HighlightCacheBox: @unchecked Sendable {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    
    private static let highlightCache: NSCache<NSString, HighlightCacheBox> = {
        let cache = NSCache<NSString, HighlightCacheBox>()
        cache.countLimit = 500
        return cache
    }()
    
    // Convenience for default theme or dark mode
    public static func highlight(code: String, language: SyntaxLanguage, isDark: Bool = false) -> AttributedString {
        highlight(code: code, language: language, theme: isDark ? .githubDark : .githubLight)
    }
    
    public static func highlight(code: String, language: SyntaxLanguage) -> AttributedString {
        // Detect system dark mode if not explicitly passed
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return highlight(code: code, language: language, theme: isDark ? .githubDark : .githubLight)
    }
    
    // Highlight Code into AttributedString with specified SyntaxTheme
    public static func highlight(code: String, language: SyntaxLanguage, theme: SyntaxTheme) -> AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = theme.plainText
        guard language != .plain else { return attributed }
        
        let cacheKey = "\(code.hashValue)_\(language.rawValue)_\(theme.name)" as NSString
        if let cached = highlightCache.object(forKey: cacheKey) {
            return cached.value
        }
        
        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        
        // 1. Identifiers, Keywords, Types, Booleans
        let wordMatches = wordRegex.matches(in: code, range: fullRange)
        for m in wordMatches {
            let word = nsCode.substring(with: m.range)
            let lowerWord = word.lowercased()
            
            if isKeyword(lowerWord, in: language) {
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.keyword
                    attributed[r].inlinePresentationIntent = .stronglyEmphasized
                }
            } else if booleansAndLiterals.contains(lowerWord) {
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.boolean
                }
            } else if word.first?.isUppercase == true && language != .bash && language != .sql && language != .mermaid {
                // Type or Class name (PascalCase)
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.type
                }
            }
        }
        
        // 2. Function Calls (e.g. `doSomething(...)`)
        if language == .swift || language == .python || language == .javascript || language == .typescript {
            let matches = funcRegex.matches(in: code, range: fullRange)
            for m in matches {
                let range = m.range(at: 1)
                let name = nsCode.substring(with: range)
                if !isKeyword(name.lowercased(), in: language), name.first?.isUppercase != true {
                    if let r = Range(range, in: attributed) {
                        attributed[r].foregroundColor = theme.function
                    }
                }
            }
        }
        
        // 3. Numbers (Hex, Binary, Floats, Integers)
        let numMatches = numRegex.matches(in: code, range: fullRange)
        for m in numMatches {
            if let r = Range(m.range, in: attributed) {
                attributed[r].foregroundColor = theme.number
            }
        }
        
        // 4. Attributes / Decorators (@Attribute)
        if language == .swift || language == .python || language == .typescript {
            let attrMatches = attrRegex.matches(in: code, range: fullRange)
            for m in attrMatches {
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.attribute
                }
            }
        }
        
        // 5. Quoted Strings ("string", 'string', `string`)
        let strMatches = strRegex.matches(in: code, range: fullRange)
        for m in strMatches {
            if let r = Range(m.range, in: attributed) {
                attributed[r].foregroundColor = theme.string
            }
        }
        
        // 6. JSON Keys ("key": ...)
        if language == .json {
            let jsonMatches = jsonKeyRegex.matches(in: code, range: fullRange)
            for m in jsonMatches {
                let keyRange = m.range(at: 1)
                if let r = Range(keyRange, in: attributed) {
                    attributed[r].foregroundColor = theme.keyword
                }
            }
        }
        
        // 7. HTML / XML Tags & Attributes
        if language == .html {
            let tagMatches = htmlTagRegex.matches(in: code, range: fullRange)
            for m in tagMatches {
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.keyword
                }
            }
            let attrMatches = htmlAttrRegex.matches(in: code, range: fullRange)
            for m in attrMatches {
                let attrRange = m.range(at: 1)
                if let r = Range(attrRange, in: attributed) {
                    attributed[r].foregroundColor = theme.attribute
                }
            }
        }
        
        // 8. Comments (Highest precedence override)
        let commentRegexes: [NSRegularExpression]
        switch language {
        case .swift, .javascript, .typescript, .css:
            commentRegexes = [slashSlashCommentRegex, slashStarCommentRegex]
        case .python, .bash, .yaml:
            commentRegexes = [hashCommentRegex]
        case .sql:
            commentRegexes = [sqlDashCommentRegex, slashStarCommentRegex]
        case .html:
            commentRegexes = [htmlCommentRegex]
        case .mermaid:
            commentRegexes = [mermaidCommentRegex]
        default:
            commentRegexes = [slashSlashCommentRegex, hashCommentRegex]
        }
        
        for commentRegex in commentRegexes {
            let matches = commentRegex.matches(in: code, range: fullRange)
            for m in matches {
                if let r = Range(m.range, in: attributed) {
                    attributed[r].foregroundColor = theme.comment
                    attributed[r].inlinePresentationIntent = nil
                }
            }
        }
        
        highlightCache.setObject(HighlightCacheBox(attributed), forKey: cacheKey)
        return attributed
    }
    
    // MARK: - HTML Syntax Highlighting
    
    private struct HTMLToken {
        let range: NSRange
        let cssClass: String
    }
    
    private static let htmlHighlightCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    
    /// Highlights source code into HTML with CSS token spans for web rendering
    public static func highlightToHTML(code: String, language: SyntaxLanguage) -> String {
        guard language != .plain, !code.isEmpty else {
            return escapeHTML(code)
        }
        
        let cacheKey = "\(code.hashValue)_\(language.rawValue)" as NSString
        if let cached = htmlHighlightCache.object(forKey: cacheKey) {
            return cached as String
        }
        
        let nsCode = code as NSString
        let fullRange = NSRange(location: 0, length: nsCode.length)
        
        var tokens: [HTMLToken] = []
        var occupied = [Bool](repeating: false, count: nsCode.length)
        
        func addToken(range: NSRange, cssClass: String) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            let end = range.location + range.length
            guard end <= nsCode.length else { return }
            for i in range.location..<end {
                if occupied[i] { return }
            }
            for i in range.location..<end {
                occupied[i] = true
            }
            tokens.append(HTMLToken(range: range, cssClass: cssClass))
        }
        
        // 1. Comments (highest precedence)
        let commentRegexes: [NSRegularExpression]
        switch language {
        case .swift, .javascript, .typescript, .css:
            commentRegexes = [slashSlashCommentRegex, slashStarCommentRegex]
        case .python, .bash, .yaml:
            commentRegexes = [hashCommentRegex]
        case .sql:
            commentRegexes = [sqlDashCommentRegex, slashStarCommentRegex]
        case .html:
            commentRegexes = [htmlCommentRegex]
        case .mermaid:
            commentRegexes = [mermaidCommentRegex]
        default:
            commentRegexes = [slashSlashCommentRegex, hashCommentRegex]
        }
        for commentRegex in commentRegexes {
            let matches = commentRegex.matches(in: code, range: fullRange)
            for m in matches {
                addToken(range: m.range, cssClass: "tok-comment")
            }
        }
        
        // 2. JSON Keys (higher precedence than generic strings so keys are highlighted distinctly)
        if language == .json {
            let jsonMatches = jsonKeyRegex.matches(in: code, range: fullRange)
            for m in jsonMatches {
                let keyRange = NSRange(location: m.range.location, length: m.range(at: 1).length + 2)
                addToken(range: keyRange, cssClass: "tok-key")
            }
        }
        
        // 3. Strings
        let strMatches = strRegex.matches(in: code, range: fullRange)
        for m in strMatches {
            addToken(range: m.range, cssClass: "tok-str")
        }
        
        // 4. Attributes / Decorators
        if language == .swift || language == .python || language == .typescript {
            let attrMatches = attrRegex.matches(in: code, range: fullRange)
            for m in attrMatches {
                addToken(range: m.range, cssClass: "tok-attr")
            }
        }
        
        // 5. HTML Tags & Attributes
        if language == .html {
            let tagMatches = htmlTagRegex.matches(in: code, range: fullRange)
            for m in tagMatches {
                addToken(range: m.range, cssClass: "tok-tag")
            }
            let attrMatches = htmlAttrRegex.matches(in: code, range: fullRange)
            for m in attrMatches {
                addToken(range: m.range(at: 1), cssClass: "tok-attr")
            }
        }
        
        // 6. Function Calls
        if language == .swift || language == .python || language == .javascript || language == .typescript {
            let matches = funcRegex.matches(in: code, range: fullRange)
            for m in matches {
                let fnRange = m.range(at: 1)
                let name = nsCode.substring(with: fnRange)
                if !isKeyword(name.lowercased(), in: language), name.first?.isUppercase != true {
                    addToken(range: fnRange, cssClass: "tok-fn")
                }
            }
        }
        
        // 7. Numbers
        let numMatches = numRegex.matches(in: code, range: fullRange)
        for m in numMatches {
            addToken(range: m.range, cssClass: "tok-num")
        }
        
        // 8. Identifiers, Keywords, Types, Booleans
        let wordMatches = wordRegex.matches(in: code, range: fullRange)
        for m in wordMatches {
            let word = nsCode.substring(with: m.range)
            let lowerWord = word.lowercased()
            if isKeyword(lowerWord, in: language) {
                addToken(range: m.range, cssClass: "tok-kw")
            } else if booleansAndLiterals.contains(lowerWord) {
                addToken(range: m.range, cssClass: "tok-bool")
            } else if word.first?.isUppercase == true && language != .bash && language != .sql && language != .mermaid {
                addToken(range: m.range, cssClass: "tok-type")
            }
        }
        
        tokens.sort { $0.range.location < $1.range.location }
        
        var result = ""
        result.reserveCapacity(code.utf8.count + tokens.count * 30)
        var currentIndex = 0
        
        for token in tokens {
            if token.range.location > currentIndex {
                let unformattedRange = NSRange(location: currentIndex, length: token.range.location - currentIndex)
                let unformattedText = nsCode.substring(with: unformattedRange)
                result += escapeHTML(unformattedText)
            }
            let tokenText = nsCode.substring(with: token.range)
            result += "<span class=\"\(token.cssClass)\">\(escapeHTML(tokenText))</span>"
            currentIndex = token.range.location + token.range.length
        }
        
        if currentIndex < nsCode.length {
            let remainingRange = NSRange(location: currentIndex, length: nsCode.length - currentIndex)
            let remainingText = nsCode.substring(with: remainingRange)
            result += escapeHTML(remainingText)
        }
        
        htmlHighlightCache.setObject(result as NSString, forKey: cacheKey)
        return result
    }
    
    public static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    private static func isKeyword(_ word: String, in language: SyntaxLanguage) -> Bool {
        switch language {
        case .swift:
            return swiftKeywords.contains(word)
        case .python:
            return pythonKeywords.contains(word)
        case .javascript, .typescript:
            return jsKeywords.contains(word)
        case .bash:
            return bashKeywords.contains(word)
        case .sql:
            return sqlKeywords.contains(word)
        case .mermaid:
            return mermaidKeywords.contains(word)
        case .json:
            return false
        default:
            return swiftKeywords.contains(word)
        }
    }
}

// MARK: - Markdown NS Theme (AppKit)

public struct MarkdownNSTheme: Sendable {
    public let name: String
    public let background: NSColor
    public let foreground: NSColor
    public let selection: NSColor
    public let cursor: NSColor
    public let heading: NSColor
    public let headingMarker: NSColor
    public let listMarker: NSColor
    public let number: NSColor
    public let taskBox: NSColor
    public let bold: NSColor
    public let italic: NSColor
    public let code: NSColor
    public let codeBlockFence: NSColor
    public let quote: NSColor
    public let link: NSColor
    public let url: NSColor
    public let tag: NSColor
    public let frontmatterKey: NSColor
    public let frontmatterVal: NSColor
    public let horizontalRule: NSColor
    
    public init(theme: TerminalTheme) {
        let bg = NSColor(hex: theme.backgroundHex) ?? (theme.isDark ? .black : .white)
        let fg = NSColor(hex: theme.foregroundHex) ?? (theme.isDark ? .white : .black)
        let sel = NSColor(hex: theme.selectionBackgroundHex) ?? (theme.isDark ? NSColor.selectedTextBackgroundColor : NSColor.selectedControlColor)
        let cur = NSColor(hex: theme.cursorColorHex) ?? (NSColor(hex: theme.selectionBackgroundHex) ?? .controlAccentColor)
        
        let p = theme.palette
        func colorAt(_ idx: Int, fallback: NSColor) -> NSColor {
            guard p.indices.contains(idx), let c = NSColor(hex: p[idx]) else { return fallback }
            return c
        }
        
        self.name = theme.displayName
        self.background = bg
        self.foreground = fg
        self.selection = sel
        self.cursor = cur
        
        // Headings: Warm yellow/gold (ANSI 3 / 11), with coral/red markers (ANSI 1 / 9)
        self.heading = colorAt(3, fallback: colorAt(11, fallback: .systemOrange))
        self.headingMarker = colorAt(1, fallback: colorAt(9, fallback: .systemRed))
        
        // Lists: Cyan/Sky Blue list markers (ANSI 6 / 14), bright numbers (ANSI 11 / 3)
        self.listMarker = colorAt(6, fallback: colorAt(14, fallback: .systemCyan))
        self.number = colorAt(11, fallback: colorAt(3, fallback: .systemYellow))
        self.taskBox = colorAt(2, fallback: colorAt(10, fallback: .systemGreen))
        
        // Bold / Italic
        self.bold = fg
        self.italic = colorAt(5, fallback: colorAt(13, fallback: .systemPurple))
        
        // Code
        self.code = colorAt(2, fallback: colorAt(10, fallback: .systemGreen))
        self.codeBlockFence = colorAt(8, fallback: .systemGray)
        
        // Quotes
        self.quote = colorAt(8, fallback: .systemGray)
        
        // Links
        self.link = colorAt(4, fallback: colorAt(12, fallback: .systemBlue))
        self.url = colorAt(8, fallback: .systemGray)
        
        // Tags
        self.tag = colorAt(5, fallback: colorAt(13, fallback: .systemPurple))
        
        // Frontmatter
        self.frontmatterKey = colorAt(6, fallback: colorAt(14, fallback: .systemCyan))
        self.frontmatterVal = colorAt(2, fallback: colorAt(10, fallback: .systemGreen))
        self.horizontalRule = colorAt(8, fallback: .systemGray)
    }
}

// MARK: - Markdown Syntax Highlighter Engine

public struct MarkdownSyntaxHighlighter: Sendable {
    
    private static let frontmatterRegex = try! NSRegularExpression(
        pattern: "\\A---[ \\t]*\\R([\\s\\S]*?)\\R---[ \\t]*(?:\\R|\\z)"
    )
    private static let frontmatterKeyRegex = try! NSRegularExpression(
        pattern: "^([a-zA-Z0-9_-]+):\\s*(.*)$",
        options: [.anchorsMatchLines]
    )
    private static let headingRegex = try! NSRegularExpression(
        pattern: "^(#{1,6})\\s+(.*)$",
        options: [.anchorsMatchLines]
    )
    private static let bulletListRegex = try! NSRegularExpression(
        pattern: "^(\\s*)([-*+])\\s+",
        options: [.anchorsMatchLines]
    )
    private static let numberListRegex = try! NSRegularExpression(
        pattern: "^(\\s*)(\\d+\\.)\\s+",
        options: [.anchorsMatchLines]
    )
    private static let taskBoxRegex = try! NSRegularExpression(
        pattern: "^(\\s*[-*+]\\s+)(\\[[ xX]\\])",
        options: [.anchorsMatchLines]
    )
    private static let blockquoteRegex = try! NSRegularExpression(
        pattern: "^(\\s*>+)\\s*(.*)$",
        options: [.anchorsMatchLines]
    )
    private static let hrRegex = try! NSRegularExpression(
        pattern: "^(\\s*[-*_]{3,}\\s*)$",
        options: [.anchorsMatchLines]
    )
    private static let boldItalicRegex = try! NSRegularExpression(
        pattern: "(\\*{3}|_{3})(?=\\S)(.+?)(?<=\\S)\\1"
    )
    private static let boldRegex = try! NSRegularExpression(
        pattern: "(\\*{2}|_{2})(?=\\S)(.+?)(?<=\\S)\\1"
    )
    private static let italicRegex = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)|(?<!_)_([^\\n_]+)_(?!_)"
    )
    private static let strikethroughRegex = try! NSRegularExpression(
        pattern: "~~(?=\\S)(.+?)(?<=\\S)~~"
    )
    private static let linkRegex = try! NSRegularExpression(
        pattern: "(\\[)(.+?)(\\]\\()(.+?)(\\))"
    )
    private static let imageRegex = try! NSRegularExpression(
        pattern: "(!\\[)(.*?)(\\]\\()(.+?)(\\))"
    )
    private static let tagRegex = try! NSRegularExpression(
        pattern: "(?<=^|\\s)#([a-zA-Z0-9_-]+)"
    )
    private static let inlineCodeRegex = try! NSRegularExpression(
        pattern: "(`[^`\\n]+`)"
    )
    private static let codeBlockRegex = try! NSRegularExpression(
        pattern: "(?s)(```[a-zA-Z0-9_-]*\\n.*?\\n```)"
    )
    
    public static func highlight(textStorage: NSTextStorage, theme: MarkdownNSTheme, baseFont: NSFont) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard fullRange.length > 0 else { return }
        
        let boldFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold), size: baseFont.pointSize) ?? baseFont
        let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) ?? baseFont
        let boldItalicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits([.bold, .italic]), size: baseFont.pointSize) ?? boldFont
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        
        // 1. Reset base styling
        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.foreground,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)
        
        // 2. YAML Frontmatter
        if let fmMatch = frontmatterRegex.firstMatch(in: string, range: fullRange) {
            textStorage.addAttribute(.foregroundColor, value: theme.quote, range: fmMatch.range)
            let innerRange = fmMatch.range(at: 1)
            let keyMatches = frontmatterKeyRegex.matches(in: string, range: innerRange)
            for km in keyMatches {
                let keyRange = km.range(at: 1)
                let valRange = km.range(at: 2)
                textStorage.addAttribute(.foregroundColor, value: theme.frontmatterKey, range: keyRange)
                textStorage.addAttribute(.font, value: boldFont, range: keyRange)
                if valRange.length > 0 {
                    textStorage.addAttribute(.foregroundColor, value: theme.frontmatterVal, range: valRange)
                }
            }
        }
        
        // 3. Headings (# Title)
        let headingMatches = headingRegex.matches(in: string, range: fullRange)
        for m in headingMatches {
            let markRange = m.range(at: 1)
            let titleRange = m.range(at: 2)
            let hashCount = markRange.length
            
            // Subtle visual scale factor for headings in raw text
            let scale: CGFloat
            switch hashCount {
            case 1: scale = 1.25
            case 2: scale = 1.15
            case 3: scale = 1.08
            default: scale = 1.0
            }
            let headingFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold), size: baseFont.pointSize * scale) ?? boldFont
            
            textStorage.addAttribute(.foregroundColor, value: theme.headingMarker, range: markRange)
            textStorage.addAttribute(.font, value: headingFont, range: markRange)
            
            if titleRange.length > 0 {
                textStorage.addAttribute(.foregroundColor, value: theme.heading, range: titleRange)
                textStorage.addAttribute(.font, value: headingFont, range: titleRange)
            }
        }
        
        // 4. Blockquotes (> Quote)
        let quoteMatches = blockquoteRegex.matches(in: string, range: fullRange)
        for m in quoteMatches {
            let markRange = m.range(at: 1)
            let textRange = m.range(at: 2)
            textStorage.addAttribute(.foregroundColor, value: theme.quote, range: markRange)
            textStorage.addAttribute(.font, value: boldFont, range: markRange)
            if textRange.length > 0 {
                textStorage.addAttribute(.foregroundColor, value: theme.quote, range: textRange)
                textStorage.addAttribute(.font, value: italicFont, range: textRange)
            }
        }
        
        // 5. Unordered List Bullets (- , * , + )
        let bulletMatches = bulletListRegex.matches(in: string, range: fullRange)
        for m in bulletMatches {
            let markRange = m.range(at: 2)
            textStorage.addAttribute(.foregroundColor, value: theme.listMarker, range: markRange)
            textStorage.addAttribute(.font, value: boldFont, range: markRange)
        }
        
        // 6. Numbered Lists (1. , 2. )
        let numberMatches = numberListRegex.matches(in: string, range: fullRange)
        for m in numberMatches {
            let markRange = m.range(at: 2)
            textStorage.addAttribute(.foregroundColor, value: theme.number, range: markRange)
            textStorage.addAttribute(.font, value: boldFont, range: markRange)
        }
        
        // 7. Task Checkboxes ([ ], [x])
        let taskMatches = taskBoxRegex.matches(in: string, range: fullRange)
        for m in taskMatches {
            let boxRange = m.range(at: 2)
            textStorage.addAttribute(.foregroundColor, value: theme.taskBox, range: boxRange)
            textStorage.addAttribute(.font, value: boldFont, range: boxRange)
        }
        
        // 8. Horizontal Rules (---, ***)
        let hrMatches = hrRegex.matches(in: string, range: fullRange)
        for m in hrMatches {
            textStorage.addAttribute(.foregroundColor, value: theme.horizontalRule, range: m.range)
        }
        
        // 9. Bold + Italic (***text***)
        let boldItalicMatches = boldItalicRegex.matches(in: string, range: fullRange)
        for m in boldItalicMatches {
            textStorage.addAttribute(.font, value: boldItalicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: theme.bold, range: m.range)
        }
        
        // 10. Bold (**text**)
        let boldMatches = boldRegex.matches(in: string, range: fullRange)
        for m in boldMatches {
            textStorage.addAttribute(.font, value: boldFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: theme.bold, range: m.range)
        }
        
        // 11. Italic (*text*)
        let italicMatches = italicRegex.matches(in: string, range: fullRange)
        for m in italicMatches {
            textStorage.addAttribute(.font, value: italicFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: theme.italic, range: m.range)
        }
        
        // 12. Strikethrough (~~text~~)
        let strikeMatches = strikethroughRegex.matches(in: string, range: fullRange)
        for m in strikeMatches {
            textStorage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            textStorage.addAttribute(.strikethroughColor, value: theme.horizontalRule, range: m.range)
        }
        
        // 13. Links & Images ([text](url), ![alt](url))
        let imgMatches = imageRegex.matches(in: string, range: fullRange)
        for m in imgMatches {
            textStorage.addAttribute(.foregroundColor, value: theme.headingMarker, range: m.range(at: 1))
        }
        
        let linkMatches = linkRegex.matches(in: string, range: fullRange)
        for m in linkMatches {
            let labelRange = m.range(at: 2)
            let urlRange = m.range(at: 4)
            textStorage.addAttribute(.foregroundColor, value: theme.url, range: m.range(at: 1)) // [
            textStorage.addAttribute(.foregroundColor, value: theme.link, range: labelRange) // text
            textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: labelRange)
            textStorage.addAttribute(.foregroundColor, value: theme.url, range: m.range(at: 3)) // ](
            textStorage.addAttribute(.foregroundColor, value: theme.url, range: urlRange) // url
            textStorage.addAttribute(.foregroundColor, value: theme.url, range: m.range(at: 5)) // )
        }
        
        // 14. Tags (#tag)
        let tagMatches = tagRegex.matches(in: string, range: fullRange)
        for m in tagMatches {
            textStorage.addAttribute(.foregroundColor, value: theme.tag, range: m.range)
            textStorage.addAttribute(.font, value: boldFont, range: m.range)
        }
        
        // 15. Inline Code (`code`)
        let codeMatches = inlineCodeRegex.matches(in: string, range: fullRange)
        for m in codeMatches {
            textStorage.addAttribute(.font, value: monoFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: theme.code, range: m.range)
            textStorage.addAttribute(.backgroundColor, value: theme.code.withAlphaComponent(0.12), range: m.range)
        }
        
        // 16. Code Blocks (```lang ... ```)
        let blockMatches = codeBlockRegex.matches(in: string, range: fullRange)
        for m in blockMatches {
            textStorage.addAttribute(.font, value: monoFont, range: m.range)
            textStorage.addAttribute(.foregroundColor, value: theme.code, range: m.range)
            textStorage.addAttribute(.backgroundColor, value: theme.codeBlockFence.withAlphaComponent(0.08), range: m.range)
        }
    }
    
    public static func highlightToAttributedString(markdown: String, theme: MarkdownNSTheme, baseFont: NSFont) -> NSAttributedString {
        let storage = NSTextStorage(string: markdown)
        highlight(textStorage: storage, theme: theme, baseFont: baseFont)
        return storage
    }
}

