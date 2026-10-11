//
//  MarkdownQuickLookTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

struct MarkdownQuickLookTests {
    @Test func rendersMarkdownAsStaticHTML() {
        let preview = MarkdownQuickLook.render(markdown: """
            ---
            title: Launch
            ---
            # Launch plan

            Some **bold** text and `code`.

            | A | B |
            |---|---|
            | 1 | 2 |

            ```swift
            let answer = 42
            ```
            """, fileURL: nil)
        #expect(preview.html.contains("<h1"))
        #expect(preview.html.contains("Launch plan"))
        #expect(preview.html.contains("<strong>bold</strong>"))
        #expect(preview.html.contains("<table"))
        #expect(preview.html.contains("answer"))
        #expect(preview.html.contains("Launch")) // frontmatter
        #expect(!preview.html.contains("<script"), "Quick Look previews carry no scripts")
    }

    @Test func blocksTheNetworkAndFollowsTheSystemAppearance() {
        let html = MarkdownQuickLook.render(markdown: "![remote](https://example.com/pixel.png)", fileURL: nil).html
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("default-src 'none'"))
        #expect(!MarkdownQuickLook.contentSecurityPolicy.contains("http"))
        #expect(html.contains("@media (prefers-color-scheme: dark)"))
        #expect(html.contains(".copy-button { display: none !important; }"))
    }

    @Test func mermaidDiagramsShowAsCode() {
        let html = MarkdownQuickLook.render(markdown: "```mermaid\ngraph TD\n  A --> B\n```", fileURL: nil).html
        #expect(!html.contains("<div class=\"mermaid"))
        #expect(html.contains("language-mermaid")) // a highlighted code block instead
    }

    @Test func localImagesBecomeAttachments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent("img/chart one.png"))
        let note = folder.appendingPathComponent("note.md")

        let preview = MarkdownQuickLook.render(markdown: """
            ![Chart](img/chart%20one.png)

            Inline ![again](img/chart%20one.png) and ![missing](img/nope.png).
            """, fileURL: note)
        #expect(preview.images.count == 1)
        let attached = try #require(preview.images.values.first)
        #expect(attached.lastPathComponent == "chart one.png")
        #expect(!preview.html.contains("file://"))
        #expect(preview.html.components(separatedBy: "src=\"cid:").count - 1 == 2) // both references
    }

    /// Regression: paragraphs, lists, tables and alerts rendered inline images without the note's
    /// location, so relative images were missing from PDF export and Quick Look.
    @Test func inlineImagesResolveRelativeToTheNoteEverywhere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0x89]).write(to: folder.appendingPathComponent("dot.png"))
        let html = MarkdownHTMLRenderer.renderHTML(markdown: """
            Paragraph ![p](dot.png)

            - List ![l](dot.png)
            - [ ] Task ![t](dot.png)

            | Image |
            |---|
            | ![c](dot.png) |

            > [!NOTE]
            > Alert ![a](dot.png)
            """, theme: TerminalThemes.all[0], contentWidth: 800, noteURL: folder.appendingPathComponent("note.md"))
        let resolved = html.components(separatedBy: "<img src=\"file://").count - 1
        #expect(resolved == 5, "\(resolved) of 5 inline images resolved")
        #expect(!html.contains("src=\"dot.png\""))
    }
}
