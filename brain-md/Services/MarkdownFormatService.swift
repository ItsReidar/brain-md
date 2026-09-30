//
//  MarkdownFormatService.swift
//  brain-md
//

import Foundation
import AppKit

public enum MarkdownFormatElement: Hashable, Sendable {
    case heading(level: Int)
    case paragraph
    case lineBreak
    case bold
    case italic
    case boldItalic
    case strikethrough
    case blockquote
    case unorderedList
    case orderedList
    case taskList
    case inlineCode
    case codeBlock
    case horizontalRule
    case link
    case image
    case escapingCharacters
    case html
}

public struct MarkdownFormatResult: Equatable, Sendable {
    public let replacementText: String
    public let replacementRange: NSRange
    public let newSelectedRange: NSRange
    
    public init(replacementText: String, replacementRange: NSRange, newSelectedRange: NSRange) {
        self.replacementText = replacementText
        self.replacementRange = replacementRange
        self.newSelectedRange = newSelectedRange
    }
}

public struct MarkdownFormatService: Sendable {
    public static let notificationName = Notification.Name("ApplyMarkdownFormatNotification")
    
    /// Pure function returning text replacement and resulting selection.
    public static func format(
        element: MarkdownFormatElement,
        fullText: String,
        selectedRange: NSRange
    ) -> MarkdownFormatResult {
        let nsString = fullText as NSString
        let safeRange = clampRange(selectedRange, length: nsString.length)
        let selectedText = nsString.substring(with: safeRange)
        let hasSelection = safeRange.length > 0
        
        switch element {
        case .heading(let level):
            let clampedLevel = max(1, min(6, level))
            let prefix = String(repeating: "#", count: clampedLevel) + " "
            
            if hasSelection {
                // If single line or selection
                let cleaned = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                let textToInsert = prefix + cleaned
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (textToInsert as NSString).length)
                )
            } else {
                // Expand to entire line
                let lineRange = nsString.lineRange(for: safeRange)
                let lineText = nsString.substring(with: lineRange)
                let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if trimmedLine.isEmpty {
                    let placeholder = "Heading \(clampedLevel)"
                    let textToInsert = prefix + placeholder + "\n"
                    return MarkdownFormatResult(
                        replacementText: textToInsert,
                        replacementRange: lineRange,
                        newSelectedRange: NSRange(location: lineRange.location + (prefix as NSString).length, length: (placeholder as NSString).length)
                    )
                } else {
                    let stripped = trimmedLine.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                    let textToInsert = prefix + stripped + (lineText.hasSuffix("\n") ? "\n" : "")
                    return MarkdownFormatResult(
                        replacementText: textToInsert,
                        replacementRange: lineRange,
                        newSelectedRange: NSRange(location: lineRange.location + (textToInsert as NSString).length - (lineText.hasSuffix("\n") ? 1 : 0), length: 0)
                    )
                }
            }
            
        case .paragraph:
            if hasSelection {
                let textToInsert = "\n\n" + selectedText + "\n\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "Paragraph text"
                let textToInsert = "\n\n" + placeholder + "\n\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (placeholder as NSString).length)
                )
            }
            
        case .lineBreak:
            let textToInsert = "  \n"
            return MarkdownFormatResult(
                replacementText: textToInsert,
                replacementRange: safeRange,
                newSelectedRange: NSRange(location: safeRange.location + (textToInsert as NSString).length, length: 0)
            )
            
        case .bold:
            if hasSelection {
                let textToInsert = "**\(selectedText)**"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "Bold text"
                let textToInsert = "**\(placeholder)**"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (placeholder as NSString).length)
                )
            }
            
        case .italic:
            if hasSelection {
                let textToInsert = "*\(selectedText)*"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 1, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "Italic text"
                let textToInsert = "*\(placeholder)*"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 1, length: (placeholder as NSString).length)
                )
            }
            
        case .boldItalic:
            if hasSelection {
                let textToInsert = "***\(selectedText)***"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 3, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "Bold and Italic text"
                let textToInsert = "***\(placeholder)***"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 3, length: (placeholder as NSString).length)
                )
            }
            
        case .strikethrough:
            if hasSelection {
                let textToInsert = "~~\(selectedText)~~"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "Strikethrough text"
                let textToInsert = "~~\(placeholder)~~"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (placeholder as NSString).length)
                )
            }
            
        case .blockquote:
            if hasSelection {
                let lines = selectedText.components(separatedBy: "\n")
                let quotedLines = lines.map { "> " + $0 }.joined(separator: "\n")
                return MarkdownFormatResult(
                    replacementText: quotedLines,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (quotedLines as NSString).length)
                )
            } else {
                let lineRange = nsString.lineRange(for: safeRange)
                let lineText = nsString.substring(with: lineRange)
                let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let placeholder = "Blockquote"
                    let textToInsert = "> " + placeholder + "\n"
                    return MarkdownFormatResult(
                        replacementText: textToInsert,
                        replacementRange: lineRange,
                        newSelectedRange: NSRange(location: lineRange.location + 2, length: (placeholder as NSString).length)
                    )
                } else {
                    let textToInsert = "> " + lineText
                    return MarkdownFormatResult(
                        replacementText: textToInsert,
                        replacementRange: lineRange,
                        newSelectedRange: NSRange(location: lineRange.location + (textToInsert as NSString).length, length: 0)
                    )
                }
            }
            
        case .unorderedList:
            if hasSelection {
                let lines = selectedText.components(separatedBy: "\n")
                let listLines = lines.map { "- " + $0 }.joined(separator: "\n")
                return MarkdownFormatResult(
                    replacementText: listLines,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (listLines as NSString).length)
                )
            } else {
                let placeholder = "List item"
                let textToInsert = "- \(placeholder)\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (placeholder as NSString).length)
                )
            }
            
        case .orderedList:
            if hasSelection {
                let lines = selectedText.components(separatedBy: "\n")
                let listLines = lines.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n")
                return MarkdownFormatResult(
                    replacementText: listLines,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (listLines as NSString).length)
                )
            } else {
                let placeholder = "First item"
                let textToInsert = "1. \(placeholder)\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 3, length: (placeholder as NSString).length)
                )
            }
            
        case .taskList:
            if hasSelection {
                let lines = selectedText.components(separatedBy: "\n")
                let taskLines = lines.map { "- [ ] " + $0 }.joined(separator: "\n")
                return MarkdownFormatResult(
                    replacementText: taskLines,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (taskLines as NSString).length)
                )
            } else {
                let placeholder = "Task item"
                let textToInsert = "- [ ] \(placeholder)\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 6, length: (placeholder as NSString).length)
                )
            }
            
        case .inlineCode:
            if hasSelection {
                let textToInsert = "`\(selectedText)`"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 1, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "code"
                let textToInsert = "`\(placeholder)`"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 1, length: (placeholder as NSString).length)
                )
            }
            
        case .codeBlock:
            if hasSelection {
                let textToInsert = "```\n\(selectedText)\n```\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 4, length: (selectedText as NSString).length)
                )
            } else {
                let placeholder = "// Code here"
                let textToInsert = "```\n\(placeholder)\n```\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 4, length: (placeholder as NSString).length)
                )
            }
            
        case .horizontalRule:
            let textToInsert = "\n\n---\n\n"
            return MarkdownFormatResult(
                replacementText: textToInsert,
                replacementRange: safeRange,
                newSelectedRange: NSRange(location: safeRange.location + (textToInsert as NSString).length, length: 0)
            )
            
        case .link:
            if hasSelection {
                let urlPlaceholder = "https://example.com"
                let textToInsert = "[\(selectedText)](\(urlPlaceholder))"
                let urlStart = safeRange.location + (selectedText as NSString).length + 3
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: urlStart, length: (urlPlaceholder as NSString).length)
                )
            } else {
                let titlePlaceholder = "Link title"
                let urlPlaceholder = "https://example.com"
                let textToInsert = "[\(titlePlaceholder)](\(urlPlaceholder))"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 1, length: (titlePlaceholder as NSString).length)
                )
            }
            
        case .image:
            if hasSelection {
                let urlPlaceholder = "https://example.com/image.png"
                let textToInsert = "![\(selectedText)](\(urlPlaceholder))"
                let urlStart = safeRange.location + (selectedText as NSString).length + 4
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: urlStart, length: (urlPlaceholder as NSString).length)
                )
            } else {
                let altPlaceholder = "Alt text"
                let urlPlaceholder = "https://example.com/image.png"
                let textToInsert = "![\(altPlaceholder)](\(urlPlaceholder))"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location + 2, length: (altPlaceholder as NSString).length)
                )
            }
            
        case .escapingCharacters:
            if hasSelection {
                // Escape Markdown syntax characters: \ ` * _ { } [ ] < > ( ) # + - . ! | ~
                let specialChars: Set<Character> = ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "(", ")", "#", "+", "-", ".", "!", "|", "~"]
                var escaped = ""
                for char in selectedText {
                    if specialChars.contains(char) {
                        escaped.append("\\")
                    }
                    escaped.append(char)
                }
                return MarkdownFormatResult(
                    replacementText: escaped,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (escaped as NSString).length)
                )
            } else {
                let sample = "\\*literal asterisks\\*"
                return MarkdownFormatResult(
                    replacementText: sample,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (sample as NSString).length)
                )
            }
            
        case .html:
            if hasSelection {
                let textToInsert = "<div class=\"note\">\n  \(selectedText)\n</div>\n"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: NSRange(location: safeRange.location, length: (textToInsert as NSString).length)
                )
            } else {
                let textToInsert = "<div class=\"note\">\n  <p>Content</p>\n</div>\n"
                let placeholderRange = NSRange(location: safeRange.location + 25, length: 7) // "Content"
                return MarkdownFormatResult(
                    replacementText: textToInsert,
                    replacementRange: safeRange,
                    newSelectedRange: placeholderRange
                )
            }
        }
    }
    
    private static func clampRange(_ range: NSRange, length: Int) -> NSRange {
        let loc = max(0, min(range.location, length))
        let len = max(0, min(range.length, length - loc))
        return NSRange(location: loc, length: len)
    }
}
