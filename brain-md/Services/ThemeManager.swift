//
//  ThemeManager.swift
//  brain-md
//

import SwiftUI
import Combine

/// Manages application themes, dark/light selections, and syntax theme resolution.
@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    // UserDefaults keys
    public static let appColorSchemeKey = "app_color_scheme"
    public static let selectedDarkThemeIdKey = "selected_dark_theme_id"
    public static let selectedLightThemeIdKey = "selected_light_theme_id"
    public static let customThemeOverrideKey = "custom_theme_override"
    
    @AppStorage(appColorSchemeKey) public var appColorScheme: String = "system"
    @AppStorage(selectedDarkThemeIdKey) public var selectedDarkThemeId: String = "github-dark"
    @AppStorage(selectedLightThemeIdKey) public var selectedLightThemeId: String = "github-light"
    @AppStorage(customThemeOverrideKey) public var customThemeOverride: String = "auto"
    
    @Published public var refreshTrigger: UUID = UUID()
    
    private init() {}
    
    /// Forces dependent views to re-render when a theme setting changes
    public func notifyThemeChanged() {
        refreshTrigger = UUID()
    }
    
    /// Static resolution reading directly from UserDefaults (thread-safe, callable from any actor)
    public static func resolveTheme(for colorScheme: ColorScheme) -> TerminalTheme {
        let customOverride = UserDefaults.standard.string(forKey: customThemeOverrideKey) ?? "auto"
        if customOverride != "auto", let explicit = TerminalThemes.byId[customOverride] {
            return explicit
        }
        let appScheme = UserDefaults.standard.string(forKey: appColorSchemeKey) ?? "system"
        let darkId = UserDefaults.standard.string(forKey: selectedDarkThemeIdKey) ?? "github-dark"
        let lightId = UserDefaults.standard.string(forKey: selectedLightThemeIdKey) ?? "github-light"
        
        if appScheme == "dark" {
            return TerminalThemes.byId[darkId] ?? TerminalThemes.byId["github-dark"] ?? TerminalThemes.dark[0]
        }
        if appScheme == "light" {
            return TerminalThemes.byId[lightId] ?? TerminalThemes.byId["github-light"] ?? TerminalThemes.light[0]
        }
        if colorScheme == .dark {
            return TerminalThemes.byId[darkId] ?? TerminalThemes.byId["github-dark"] ?? TerminalThemes.dark[0]
        } else {
            return TerminalThemes.byId[lightId] ?? TerminalThemes.byId["github-light"] ?? TerminalThemes.light[0]
        }
    }
    
    /// Determines the active theme based on user preferences and environment color scheme.
    public func currentTheme(for colorScheme: ColorScheme) -> TerminalTheme {
        ThemeManager.resolveTheme(for: colorScheme)
    }
    
    /// Returns the active syntax theme for code blocks and diagrams
    public func currentSyntaxTheme(for colorScheme: ColorScheme) -> SyntaxTheme {
        currentTheme(for: colorScheme).toSyntaxTheme()
    }
    
    /// Resolves the effective ColorScheme to apply to SwiftUI view hierarchies (nil means follow macOS system)
    public var effectiveColorScheme: ColorScheme? {
        if customThemeOverride != "auto", let explicit = TerminalThemes.byId[customThemeOverride] {
            return explicit.isDark ? .dark : .light
        }
        if appColorScheme == "dark" { return .dark }
        if appColorScheme == "light" { return .light }
        return nil
    }
}
