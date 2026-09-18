//
//  TerminalTheme.swift
//  brain-md
//

import SwiftUI

/// Represents a terminal color scheme imported from terminalcolors.com
public struct TerminalTheme: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let themeFamily: String
    public let variantName: String
    public let displayName: String
    public let isDark: Bool
    public let backgroundHex: String
    public let foregroundHex: String
    public let selectionBackgroundHex: String
    public let selectionForegroundHex: String
    public let cursorColorHex: String
    public let cursorTextHex: String
    public let palette: [String] // 16-color ANSI hex palette
    
    public init(
        id: String,
        themeFamily: String,
        variantName: String,
        displayName: String,
        isDark: Bool,
        backgroundHex: String,
        foregroundHex: String,
        selectionBackgroundHex: String,
        selectionForegroundHex: String,
        cursorColorHex: String,
        cursorTextHex: String,
        palette: [String]
    ) {
        self.id = id
        self.themeFamily = themeFamily
        self.variantName = variantName
        self.displayName = displayName
        self.isDark = isDark
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.selectionBackgroundHex = selectionBackgroundHex
        self.selectionForegroundHex = selectionForegroundHex
        self.cursorColorHex = cursorColorHex
        self.cursorTextHex = cursorTextHex
        self.palette = palette
    }
    
    public var background: Color {
        Color(hex: backgroundHex) ?? (isDark ? .black : .white)
    }
    
    public var foreground: Color {
        Color(hex: foregroundHex) ?? (isDark ? .white : .black)
    }
    
    public var accent: Color {
        Color(hex: selectionBackgroundHex) ?? .blue
    }
    
    /// Converts the terminal palette into a high-contrast SyntaxTheme for code blocks and Mermaid diagrams.
    public func toSyntaxTheme() -> SyntaxTheme {
        // ANSI 16-color indices:
        // 0: Black, 1: Red, 2: Green, 3: Yellow, 4: Blue, 5: Magenta, 6: Cyan, 7: White
        // 8: BrBlack, 9: BrRed, 10: BrGreen, 11: BrYellow, 12: BrBlue, 13: BrMagenta, 14: BrCyan, 15: BrWhite
        let keywordColor = palette.indices.contains(1) ? (Color(hex: palette[1]) ?? .red) : .red
        let typeColor = palette.indices.contains(5) ? (Color(hex: palette[5]) ?? .purple) : (palette.indices.contains(3) ? (Color(hex: palette[3]) ?? .yellow) : .purple)
        let stringColor = palette.indices.contains(2) ? (Color(hex: palette[2]) ?? .green) : .green
        let commentColor = palette.indices.contains(8) ? (Color(hex: palette[8]) ?? .gray) : .gray
        let numberColor = palette.indices.contains(11) ? (Color(hex: palette[11]) ?? .orange) : (palette.indices.contains(3) ? (Color(hex: palette[3]) ?? .orange) : .orange)
        let attributeColor = palette.indices.contains(6) ? (Color(hex: palette[6]) ?? .cyan) : .cyan
        let booleanColor = palette.indices.contains(9) ? (Color(hex: palette[9]) ?? keywordColor) : keywordColor
        let functionColor = palette.indices.contains(4) ? (Color(hex: palette[4]) ?? .blue) : .blue
        
        let headerBgHex = isDark ? (palette.indices.contains(0) ? palette[0] : backgroundHex) : (palette.indices.contains(7) ? palette[7] : backgroundHex)
        let headerBg = Color(hex: headerBgHex) ?? background
        let border = Color(hex: palette.indices.contains(8) ? palette[8] : selectionBackgroundHex) ?? Color.gray.opacity(0.3)
        
        return SyntaxTheme(
            name: displayName,
            keyword: keywordColor,
            type: typeColor,
            string: stringColor,
            comment: commentColor,
            number: numberColor,
            attribute: attributeColor,
            boolean: booleanColor,
            function: functionColor,
            plainText: foreground,
            background: background,
            headerBackground: headerBg,
            border: border
        )
    }
}
