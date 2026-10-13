//
//  MathTests.swift
//  brain-mdTests
//

import AppKit
import Foundation
import Testing
@testable import brain_md

struct MathSyntaxTests {
    @Test func inlineMathIsFoundButPricesAndCodeStayText() {
        #expect(MathSyntax.inlineSegments("Area $\\pi r^2$ here")
                == [.text("Area "), .math("\\pi r^2"), .text(" here")])
        #expect(MathSyntax.inlineSegments("Costs $5 and $10 today") == [.text("Costs $5 and $10 today")])
        #expect(MathSyntax.inlineSegments("Not math: \\$x$") == [.text("Not math: \\$x$")])
        #expect(MathSyntax.inlineSegments("Code `$x$` stays") == [.text("Code `$x$` stays")])
        #expect(MathSyntax.inlineSegments("Spaced $ x$ isn't math") == [.text("Spaced $ x$ isn't math")])
        #expect(MathSyntax.inlineSegments("Display $$E = mc^2$$ inline") == [.text("Display "), .math("E = mc^2"), .text(" inline")])
        #expect(MathSyntax.inlineSegments("$a$ and $b$") == [.math("a"), .text(" and "), .math("b")])
    }

    @Test func displayBlocksOnOneOrSeveralLinesAndMathFences() {
        #expect(MathSyntax.block(in: ["$$x^2$$"], at: 0)?.latex == "x^2")
        let multi = MathSyntax.block(in: ["before", "$$", "\\frac{a}{b}", "+ c", "$$", "after"], at: 1)
        #expect(multi?.latex == "\\frac{a}{b}\n+ c")
        #expect(multi?.end == 4)
        #expect(MathSyntax.block(in: ["$$", "never closed"], at: 0) == nil)
        #expect(MathSyntax.block(in: ["$5 is a price"], at: 0) == nil)

        let blocks = MarkdownPreviewView.parseDocument("Intro\n\n$$\n\\sum_{i=1}^n i\n$$\n\n```math\n\\sqrt{2}\n```").blocks
        let math = blocks.compactMap { block -> String? in
            if case .math(let latex) = block { return latex }
            return nil
        }
        #expect(math == ["\\sum_{i=1}^n i", "\\sqrt{2}"])
    }
}

struct MathRenderingTests {
    @Test func formulasRenderAndBrokenLaTeXDoesnt() throws {
        let rendered = try #require(MathRenderer.render("\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", display: true, fontSize: 17, color: .black))
        #expect(rendered.image.size.width > 20 && rendered.image.size.height > 20)
        #expect(MathRenderer.render("\\frac{1}{", display: true, fontSize: 17, color: .black) == nil)
    }

    @Test func pdfAndQuickLookHTMLShowMathAsImages() {
        let inline = MarkdownHTMLRenderer.renderInline("Energy $E = mc^2$ and $5")
        #expect(inline.contains(#"<img class="math""#) && inline.contains("data:image/png;base64,"))
        #expect(inline.contains("and $5"))

        // Quick Look's page allows only data: images and no scripts, so math must come as an image.
        let html = MarkdownQuickLook.render(markdown: "$$\n\\int_0^1 x\\,dx\n$$", fileURL: nil).html
        #expect(html.contains(#"<div class="math-block"><img class="math math-display""#))
        #expect(!html.contains("<script"))

        let broken = MarkdownQuickLook.render(markdown: "$$\\frac{1}{$$", fileURL: nil).html
        #expect(broken.contains(#"<pre class="math-error">"#))
    }
}
