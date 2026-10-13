//
//  MathRenderer.swift
//  brain-md
//
//  Draws LaTeX math natively with SwiftMath, for the preview, PDF export and Quick Look.
//

import AppKit
import SwiftMath

nonisolated enum MathRenderer {
    struct Rendered {
        let image: NSImage
        /// How far the formula reaches below the text baseline, to line it up with the text.
        let descent: CGFloat
    }

    private final class Box {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()

    /// The formula drawn in `color`, or nil when SwiftMath can't parse `latex`. Cached.
    static func render(_ latex: String, display: Bool, fontSize: CGFloat, color: NSColor) -> Rendered? {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let key = "\(display)|\(fontSize)|\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: rgb, labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        var result: Rendered?
        if error == nil, let image, image.size.width > 0 {
            result = Rendered(image: image, descent: layout?.descent ?? 0)
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }

    /// An `<img>` with the formula as a PNG, for the HTML behind PDF export and Quick Look. It's drawn
    /// at twice the size for sharp print and shown at `fontSize`; nil when the LaTeX doesn't parse.
    static func htmlImage(_ latex: String, display: Bool, fontSize: CGFloat) -> String? {
        guard let rendered = render(latex, display: display, fontSize: fontSize * 2, color: .black),
              let tiff = rendered.image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let size = rendered.image.size
        let alt = latex
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let style = String(format: "width:%.1fpx;height:%.1fpx;vertical-align:-%.1fpx", size.width / 2, size.height / 2, rendered.descent / 2)
        return "<img class=\"math\(display ? " math-display" : "")\" alt=\"\(alt)\" src=\"data:image/png;base64,\(png.base64EncodedString())\" style=\"\(style)\">"
    }
}
