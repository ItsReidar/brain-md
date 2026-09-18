//
//  Frontmatter.swift
//  brain-md
//

import Foundation

// MARK: - Frontmatter Models

public struct FrontmatterProperty: Identifiable, Hashable, Sendable {
    public var id: String { key }
    public let key: String
    public let value: String
    public let isTags: Bool
    public let tags: [String]
    
    public init(key: String, value: String, isTags: Bool = false, tags: [String] = []) {
        self.key = key
        self.value = value
        self.isTags = isTags
        self.tags = tags
    }
}

public struct ParsedFrontmatter: Equatable, Sendable {
    public let rawYAML: String
    public let properties: [FrontmatterProperty]
    public let tags: [String]
    
    public init(rawYAML: String, properties: [FrontmatterProperty], tags: [String]) {
        self.rawYAML = rawYAML
        self.properties = properties
        self.tags = tags
    }
    
    public var isEmpty: Bool {
        properties.isEmpty && tags.isEmpty
    }
    
    public var title: String? {
        properties.first(where: { $0.key.lowercased() == "title" })?.value
    }
    
    public var date: String? {
        properties.first(where: { $0.key.lowercased() == "date" || $0.key.lowercased() == "created" })?.value
    }
    
    public var author: String? {
        properties.first(where: { $0.key.lowercased() == "author" })?.value
    }
    
    public var status: String? {
        properties.first(where: { $0.key.lowercased() == "status" })?.value
    }
}

// MARK: - Frontmatter Parser

public enum FrontmatterParser {
    
    /// Parses a Markdown document into structured frontmatter (if present) and the remaining body markdown.
    public static func parse(_ text: String) -> (frontmatter: ParsedFrontmatter?, body: String) {
        // Strip BOM if present
        var cleaned = text
        if cleaned.hasPrefix("\u{FEFF}") {
            cleaned = String(cleaned.dropFirst())
        }
        
        // Frontmatter must begin on the very first non-empty line with '---'
        let lines = cleaned.components(separatedBy: "\n")
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (nil, text)
        }
        
        let firstLine = lines[firstIndex].trimmingCharacters(in: .whitespaces)
        guard firstLine == "---" else {
            return (nil, text)
        }
        
        // Find closing '---' or '...' delimiter
        var closingIndex: Int? = nil
        for i in (firstIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." {
                closingIndex = i
                break
            }
        }
        
        guard let closingIdx = closingIndex else {
            // Unclosed frontmatter - treat as regular text
            return (nil, text)
        }
        
        let yamlLines = Array(lines[(firstIndex + 1)..<closingIdx])
        let rawYAML = yamlLines.joined(separator: "\n")
        
        // Extract remaining body
        let bodyLines = Array(lines[(closingIdx + 1)...])
        var body = bodyLines.joined(separator: "\n")
        if body.hasPrefix("\n") {
            body = String(body.dropFirst())
        }
        
        let (properties, allTags) = parseYAMLProperties(yamlLines)
        
        if properties.isEmpty && allTags.isEmpty && rawYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (nil, body)
        }
        
        let parsed = ParsedFrontmatter(rawYAML: rawYAML, properties: properties, tags: allTags)
        return (parsed, body)
    }
    
    // MARK: - YAML Property Extractor
    
    private static func parseYAMLProperties(_ lines: [String]) -> (properties: [FrontmatterProperty], tags: [String]) {
        var properties: [FrontmatterProperty] = []
        var collectedTags: [String] = []
        var seenTags = Set<String>()
        
        var currentKey: String? = nil
        var currentListItems: [String] = []
        
        func commitCurrentListIfAny() {
            guard let key = currentKey, !currentListItems.isEmpty else { return }
            let isTagKey = isTagPropertyKey(key)
            let formattedValue = currentListItems.joined(separator: ", ")
            
            var itemTags: [String] = []
            if isTagKey {
                for item in currentListItems {
                    let cleaned = cleanTag(item)
                    if !cleaned.isEmpty {
                        itemTags.append(cleaned)
                        if !seenTags.contains(cleaned) {
                            seenTags.insert(cleaned)
                            collectedTags.append(cleaned)
                        }
                    }
                }
            }
            
            properties.append(FrontmatterProperty(
                key: key,
                value: formattedValue,
                isTags: isTagKey,
                tags: itemTags
            ))
            currentKey = nil
            currentListItems = []
        }
        
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Multiline list item: e.g. "  - myTag" or "- myTag"
            if trimmed.hasPrefix("- ") && currentKey != nil {
                let itemVal = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let cleanedVal = stripQuotes(itemVal)
                if !cleanedVal.isEmpty {
                    currentListItems.append(cleanedVal)
                }
                continue
            }
            
            // New Key-Value pair
            if let colonRange = trimmed.range(of: ":") {
                commitCurrentListIfAny()
                
                let keyCandidate = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let valCandidate = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                
                let cleanKey = stripQuotes(keyCandidate)
                guard !cleanKey.isEmpty else { continue }
                
                if valCandidate.isEmpty {
                    // Possible beginning of multiline list
                    currentKey = cleanKey
                    currentListItems = []
                } else if valCandidate.hasPrefix("[") && valCandidate.hasSuffix("]") {
                    // Inline array: e.g. [swift, macos, mcp]
                    let inner = String(valCandidate.dropFirst().dropLast())
                    let rawItems = inner.split(separator: ",").map { stripQuotes(String($0).trimmingCharacters(in: .whitespaces)) }
                    let isTagKey = isTagPropertyKey(cleanKey)
                    
                    var itemTags: [String] = []
                    if isTagKey {
                        for item in rawItems {
                            let cleaned = cleanTag(item)
                            if !cleaned.isEmpty {
                                itemTags.append(cleaned)
                                if !seenTags.contains(cleaned) {
                                    seenTags.insert(cleaned)
                                    collectedTags.append(cleaned)
                                }
                            }
                        }
                    }
                    
                    properties.append(FrontmatterProperty(
                        key: cleanKey,
                        value: rawItems.joined(separator: ", "),
                        isTags: isTagKey,
                        tags: itemTags
                    ))
                } else {
                    // Normal scalar value (e.g. string, number, boolean, or comma-separated list)
                    let cleanVal = stripQuotes(valCandidate)
                    let isTagKey = isTagPropertyKey(cleanKey)
                    
                    var itemTags: [String] = []
                    if isTagKey {
                        // Could be comma-separated list like "swift, macos, mcp" or single tag
                        let parts = cleanVal.contains(",") ? cleanVal.split(separator: ",").map(String.init) : [cleanVal]
                        for part in parts {
                            let cleaned = cleanTag(part)
                            if !cleaned.isEmpty {
                                itemTags.append(cleaned)
                                if !seenTags.contains(cleaned) {
                                    seenTags.insert(cleaned)
                                    collectedTags.append(cleaned)
                                }
                            }
                        }
                    }
                    
                    properties.append(FrontmatterProperty(
                        key: cleanKey,
                        value: cleanVal,
                        isTags: isTagKey,
                        tags: itemTags
                    ))
                }
            }
        }
        
        commitCurrentListIfAny()
        return (properties, collectedTags)
    }
    
    // MARK: - Tag Sanitization Helpers
    
    public static func isTagPropertyKey(_ key: String) -> Bool {
        let lower = key.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "tags" || lower == "tag" || lower == "categories" || lower == "category" || lower == "keywords"
    }
    
    public static func cleanTag(_ tag: String) -> String {
        var t = stripQuotes(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        while t.hasPrefix("#") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
    
    public static func stripQuotes(_ s: String) -> String {
        var res = stripTrailingComment(s.trimmingCharacters(in: .whitespacesAndNewlines))
        
        var changed = true
        while changed && res.count >= 2 {
            changed = false
            let hasDouble = (res.hasPrefix("\"") && res.hasSuffix("\"")) ||
                            (res.hasPrefix("“") && res.hasSuffix("”")) ||
                            (res.hasPrefix("”") && res.hasSuffix("”")) ||
                            (res.hasPrefix("“") && res.hasSuffix("\"")) ||
                            (res.hasPrefix("\"") && res.hasSuffix("”"))
            let hasSingle = (res.hasPrefix("'") && res.hasSuffix("'")) ||
                            (res.hasPrefix("‘") && res.hasSuffix("’")) ||
                            (res.hasPrefix("’") && res.hasSuffix("’")) ||
                            (res.hasPrefix("‘") && res.hasSuffix("'")) ||
                            (res.hasPrefix("'") && res.hasSuffix("’"))
            
            if hasDouble || hasSingle {
                res = String(res.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        
        // Handle empty or stray quote strings
        if res == "\"\"" || res == "''" || res == "“”" || res == "‘’" || res == "\"" || res == "'" || res == "“" || res == "”" || res == "‘" || res == "’" {
            return ""
        }
        
        return res.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public static func stripTrailingComment(_ s: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        let chars = Array(s)
        
        for i in 0..<chars.count {
            let c = chars[i]
            if c == "'" || c == "‘" || c == "’" {
                inSingleQuote.toggle()
            } else if c == "\"" || c == "“" || c == "”" {
                inDoubleQuote.toggle()
            } else if c == "#" && !inSingleQuote && !inDoubleQuote {
                // Must be preceded by whitespace and followed by whitespace or end of line (e.g. ' # comment')
                // This ensures '#tag' or '#hex' values are preserved.
                let precededByWhitespace = (i > 0 && chars[i - 1].isWhitespace)
                let followedByWhitespaceOrEnd = (i + 1 == chars.count || chars[i + 1].isWhitespace)
                
                if precededByWhitespace && followedByWhitespaceOrEnd {
                    return String(chars[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
