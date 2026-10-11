//
//  MarkdownQuickLook.swift
//  brain-md
//
//  Markdown rendered for Finder's Quick Look (the brain-md-QuickLook extension compiles this file).
//

import Foundation

/// Static HTML for a Quick Look preview, built from the same renderer as PDF export. Unlike the app
/// it has no scripts: Mermaid diagrams show as code and copy buttons are hidden. It carries light
/// and dark styles and follows the system appearance. A content security policy keeps the preview
/// from loading anything from the network; local images travel along as attachments.
nonisolated enum MarkdownQuickLook {
    struct Preview: Equatable {
        let html: String
        /// Local images referenced by the HTML as `cid:<key>`.
        let images: [String: URL]
    }

    static let lightThemeID = "github-light"
    static let darkThemeID = "github-dark"
    static let contentWidth = 850.0

    /// Blocks scripts, frames and network loads; allows inline styles and attached or inline images.
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src cid: data:"

    static func render(markdown: String, fileURL: URL?) -> Preview {
        let (frontmatter, body) = FrontmatterParser.parse(markdown)
        let document = MarkdownPreviewView.parseDocument(frontmatter != nil ? body : markdown)
        let blocks = document.blocks.map { block -> MarkdownPreviewView.MarkdownBlock in
            if case .mermaidDiagram(let code) = block { return .codeBlock(lang: "mermaid", code: code) }
            return block
        }
        let bodyHTML = MarkdownHTMLRenderer.renderBodyHTML(blocks: blocks, footnotes: document.footnotes, noteURL: fileURL)
        let (html, images) = embedLocalImages(
            in: MarkdownHTMLRenderer.renderFrontmatterHTML(frontmatter) + "\n" + bodyHTML)
        let page = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
              <meta name="color-scheme" content="light dark">
              <style>
              \(css)
              </style>
            </head>
            <body>
              <div id="markdown-root">
              \(html)
              </div>
            </body>
            </html>
            """
        return Preview(html: page, images: images)
    }

    /// Light styles, dark styles for dark mode, and Quick Look adjustments.
    static var css: String {
        let light = TerminalThemes.byId[lightThemeID] ?? TerminalThemes.all[0]
        let dark = TerminalThemes.byId[darkThemeID] ?? TerminalThemes.all[0]
        return MarkdownHTMLRenderer.generateCSS(theme: light, contentWidth: contentWidth)
            + "\n@media (prefers-color-scheme: dark) {\n"
            + MarkdownHTMLRenderer.generateCSS(theme: dark, contentWidth: contentWidth)
            + "\n}\n"
            + ".copy-button { display: none !important; }\n"
    }

    /// Replaces `<img src="file://…">` with `cid:` references and returns the files to attach.
    static func embedLocalImages(in html: String) -> (String, [String: URL]) {
        guard let pattern = try? NSRegularExpression(pattern: #"src="(file://[^"]+)""#) else { return (html, [:]) }
        var images: [String: URL] = [:]
        var result = html
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: html), let source = Range(match.range(at: 1), in: html),
                  let url = URL(string: unescape(String(html[source])))
            else { continue }
            let key = images.first { $0.value == url }?.key ?? "image\(images.count)"
            images[key] = url
            result.replaceSubrange(Range(match.range, in: result) ?? whole, with: "src=\"cid:\(key)\"")
        }
        return (result, images)
    }

    /// Undoes `MarkdownHTMLRenderer.escapeHTML` for an attribute value.
    private static func unescape(_ string: String) -> String {
        string.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
