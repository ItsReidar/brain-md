//
//  MathSyntax.swift
//  brain-md
//
//  LaTeX math in Markdown, as GitHub and Obsidian read it: `$…$` inline, and `$$…$$` or a
//  ```math fence for a block. The preview, PDF export and Quick Look all find math through here.
//

import Foundation

nonisolated enum MathSyntax {
    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// Splits a line into text and `$…$` (or `$$…$$`) math. Pandoc's rule keeps prices plain: the
    /// opening `$` is followed by a non-space, the closing one follows a non-space and isn't followed
    /// by a digit. `\$` is a literal dollar, and code spans are left alone.
    static func inlineSegments(_ text: String) -> [Segment] {
        let chars = Array(text)
        var segments: [Segment] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { segments.append(.text(buffer)) }
            buffer = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                buffer.append(c)
                buffer.append(chars[i + 1])
                i += 2
            } else if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                let end = closingBackticks(chars, run: run, from: i + run)
                buffer += String(chars[i..<(end ?? i + run)])
                i = end ?? i + run
            } else if c == "$", let (latex, next) = math(chars, at: i) {
                flush()
                segments.append(.math(latex))
                i = next
            } else {
                buffer.append(c)
                i += 1
            }
        }
        flush()
        return segments
    }

    /// The `$$` block starting at `lines[index]`: `$$…$$` on one line, or `$$` … `$$` over several.
    /// Returns the formula and the index of the block's last line; nil if it isn't one or never closes.
    static func block(in lines: [String], at index: Int) -> (latex: String, end: Int)? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("$$") else { return nil }
        let rest = String(first.dropFirst(2))
        if rest.hasSuffix("$$"), rest.count >= 2 {
            let latex = String(rest.dropLast(2)).trimmingCharacters(in: .whitespaces)
            return latex.isEmpty ? nil : (latex, index)
        }
        var body = rest.isEmpty ? [] : [rest]
        for j in (index + 1)..<lines.count {
            let line = lines[j].trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("$$") {
                body.append(String(line.dropLast(2)))
                let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return latex.isEmpty ? nil : (latex, j)
            }
            body.append(lines[j])
        }
        return nil
    }

    private static func closingBackticks(_ chars: [Character], run: Int, from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                var count = 0
                while j + count < chars.count, chars[j + count] == "`" { count += 1 }
                if count == run { return j + count }
                j += count
            } else {
                j += 1
            }
        }
        return nil
    }

    /// The math starting with the `$` at `start`, and the index just after its closing `$`.
    private static func math(_ chars: [Character], at start: Int) -> (String, Int)? {
        let delimiter = start + 1 < chars.count && chars[start + 1] == "$" ? 2 : 1
        let open = start + delimiter
        guard open < chars.count, !chars[open].isWhitespace, chars[open] != "$" else { return nil }
        var j = open
        while j < chars.count {
            if chars[j] == "\\" {
                j += 2
                continue
            }
            if chars[j] == "$" {
                let closes = delimiter == 1 || (j + 1 < chars.count && chars[j + 1] == "$")
                let after = j + delimiter
                if closes, !chars[j - 1].isWhitespace, delimiter == 2 || after >= chars.count || !chars[after].isNumber {
                    return (String(chars[open..<j]), after)
                }
                if delimiter == 1 { return nil } // a `$` that can't close ends the attempt: "$5 and $10"
            }
            j += 1
        }
        return nil
    }
}
