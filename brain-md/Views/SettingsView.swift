//
//  SettingsView.swift
//  brain-md
//
//  A native macOS Settings window inspired by macOS System Settings (Ventura/Sonoma/Sequoia),
//  featuring a sidebar with squircle icon badges, search filtering, rounded card-based panes,
//  and an extensible architecture for future additions.
//

import AppKit
import Speech
import SwiftUI

// MARK: - Settings Tab Registry (Extensible for future additions)

public enum SettingsTab: String, CaseIterable, Identifiable {
  case general = "General"
  case appearance = "Appearance"
  case editor = "Editor & Markdown"
  case localAI = "Local AI & Voice"
  case mcpServer = "MCP Server"
  case vault = "Vault & Storage"
  case advanced = "Advanced"
  case about = "About"

  public var id: String { rawValue }

  public var iconName: String {
    switch self {
    case .general: return "gearshape.fill"
    case .appearance: return "paintpalette.fill"
    case .editor: return "doc.text.fill"
    case .localAI: return "waveform.and.mic"
    case .mcpServer: return "network"
    case .vault: return "folder.fill"
    case .advanced: return "slider.horizontal.3"
    case .about: return "info.circle.fill"
    }
  }

  public var badgeColor: Color {
    switch self {
    case .general: return Color(hex: "#8e8e93") ?? .gray
    case .appearance: return Color(hex: "#007aff") ?? .blue
    case .editor: return Color(hex: "#34c759") ?? .green
    case .localAI: return Color(hex: "#ff2d55") ?? .pink
    case .mcpServer: return Color(hex: "#af52de") ?? .purple
    case .vault: return Color(hex: "#ff9500") ?? .orange
    case .advanced: return Color(hex: "#30b0c7") ?? .teal
    case .about: return Color(hex: "#5856d6") ?? .indigo
    }
  }
}

// MARK: - Reusable UI Components

/// Squircle icon badge matching macOS System Settings
public struct SettingsSquircleIcon: View {
  let iconName: String
  let color: Color

  public init(iconName: String, color: Color) {
    self.iconName = iconName
    self.color = color
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(color)
        .frame(width: 22, height: 22)

      Image(systemName: iconName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(.white)
    }
  }
}

/// Standardized grouped card container
public struct SettingsCard<Content: View>: View {
  let title: String?
  let footer: String?
  let content: Content

  public init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title = title {
        Text(title)
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.secondary)
          .textCase(.uppercase)
          .padding(.leading, 6)
      }

      VStack(spacing: 0) {
        content
      }
      .background(Color(NSColor.controlBackgroundColor))
      .cornerRadius(10)
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
      )

      if let footer = footer {
        Text(footer)
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .padding(.leading, 6)
      }
    }
  }
}

/// Standardized row inside a SettingsCard
public struct SettingsRow<Control: View>: View {
  let title: String
  let subtitle: String?
  let icon: String?
  let control: Control

  public init(
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.control = control()
  }

  public var body: some View {
    HStack(alignment: .center, spacing: 12) {
      if let icon = icon {
        Image(systemName: icon)
          .font(.system(size: 14))
          .foregroundColor(.secondary)
          .frame(width: 20)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 13, weight: .regular))
          .foregroundColor(.primary)

        if let subtitle = subtitle {
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      control
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

// MARK: - Main Settings View

@MainActor
public struct SettingsView: View {
  @ObservedObject var vault: VaultManager
  @State private var selectedTab: SettingsTab = .general
  @State private var searchText = ""

  @MainActor
  public init() {
    self.vault = .shared
  }

  @MainActor
  public init(vault: VaultManager) {
    self.vault = vault
  }

  private var filteredTabs: [SettingsTab] {
    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
      return SettingsTab.allCases
    }
    return SettingsTab.allCases.filter {
      $0.rawValue.localizedCaseInsensitiveContains(searchText)
    }
  }

  public var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      // Sidebar
      VStack(spacing: 0) {
        // Search Bar
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 12))
            .foregroundColor(.secondary)

          TextField("Search", text: $searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))

          if !searchText.isEmpty {
            Button(action: { searchText = "" }) {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(7)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(7)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)

        // Tab list
        List(filteredTabs, selection: $selectedTab) { tab in
          NavigationLink(value: tab) {
            HStack(spacing: 10) {
              SettingsSquircleIcon(iconName: tab.iconName, color: tab.badgeColor)
              Text(tab.rawValue)
                .font(.system(size: 13))
            }
            .padding(.vertical, 2)
          }
        }
        .listStyle(.sidebar)
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      // Detail Pane
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          // Pane Header
          HStack(spacing: 12) {
            SettingsSquircleIcon(iconName: selectedTab.iconName, color: selectedTab.badgeColor)
              .scaleEffect(1.2)

            Text(selectedTab.rawValue)
              .font(.system(size: 22, weight: .bold, design: .rounded))
          }
          .padding(.bottom, 4)

          // Selected Pane Content
          switch selectedTab {
          case .general:
            GeneralSettingsPane()
          case .appearance:
            AppearanceSettingsPane()
          case .editor:
            EditorSettingsPane()
          case .localAI:
            LocalAISettingsPane()
          case .mcpServer:
            MCPServerSettingsPane()
          case .vault:
            VaultSettingsPane(vault: vault)
          case .advanced:
            AdvancedSettingsPane()
          case .about:
            AboutSettingsPane()
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(Color(NSColor.windowBackgroundColor))
    }
    .frame(minWidth: 680, minHeight: 480)
    .navigationTitle("Settings")
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Spacer()
      }
    }
    .background(SettingsWindowConfigurator())
  }
}

// MARK: - Window Alignment Configurator

@MainActor
private struct SettingsWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        configureWindow(window)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async {
      if let window = nsView.window {
        configureWindow(window)
      }
    }
  }

  private func configureWindow(_ window: NSWindow) {
    if window.toolbar == nil {
      let toolbar = NSToolbar(identifier: "brain.md.settings.toolbar")
      toolbar.allowsUserCustomization = false
      window.toolbar = toolbar
    }
    window.toolbarStyle = .unified
    window.title = "Settings"
    window.titleVisibility = .visible

    // Ensure traffic light buttons have generous, comfortable spacing from window borders
    if let close = window.standardWindowButton(.closeButton),
      let min = window.standardWindowButton(.miniaturizeButton),
      let zoom = window.standardWindowButton(.zoomButton)
    {
      if close.frame.origin.x < 20 {
        let deltaX: CGFloat = 20 - close.frame.origin.x
        close.frame.origin.x += deltaX
        min.frame.origin.x += deltaX
        zoom.frame.origin.x += deltaX
      }
    }

    // Prevent sidebar from collapsing in settings window
    if let contentView = window.contentView,
      let splitView = findSplitView(in: contentView),
      let svc = splitView.delegate as? NSSplitViewController
    {
      for item in svc.splitViewItems {
        item.canCollapse = false
        item.isCollapsed = false
      }
    }
  }

  private func findSplitView(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView {
      return split
    }
    for subview in view.subviews {
      if let found = findSplitView(in: subview) {
        return found
      }
    }
    return nil
  }
}

// MARK: - 1. General Settings Pane

public struct GeneralSettingsPane: View {
  @AppStorage("note_title_format") private var noteTitleFormat: String = "untitled"
  @AppStorage("note_title_custom_format") private var customTitleFormat: String = "{date} Note"
  @AppStorage("note_content_template_preset") private var contentPreset: String = "heading"
  @AppStorage("note_content_custom_template") private var customContentTemplate: String =
    "# {{title}}\n\n"
  @AppStorage("autosave_debounce_seconds") private var autosaveDebounce: Double = 1.0
  @AppStorage("file_watcher_enabled") private var fileWatcherEnabled: Bool = true
  @AppStorage("mcp_autostart_on_launch") private var mcpAutostart: Bool = true

  private var previewTitle: String {
    NoteTemplateEngine.resolveTitle(preset: noteTitleFormat, customFormat: customTitleFormat)
  }

  public var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Startup & New Notes") {
        // 1. Note Title Format
        SettingsRow(
          title: "New Note Title Format",
          subtitle: "Default title format when creating a new note with ⌘N"
        ) {
          Picker("", selection: $noteTitleFormat) {
            ForEach(NoteTemplateEngine.TitleFormatPreset.allCases) { preset in
              Text(preset.displayName).tag(preset.rawValue)
            }
          }
          .frame(width: 170)
        }

        if noteTitleFormat == NoteTemplateEngine.TitleFormatPreset.custom.rawValue {
          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Custom Title Format:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
              Spacer()
              Text("Preview: \(previewTitle).md")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.accentColor)
            }

            TextField("e.g. Note - {date} or {date}_{time}", text: $customTitleFormat)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 12, design: .monospaced))

            HStack(spacing: 6) {
              Text("Insert token:")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

              ForEach(["{date}", "{time}", "{year}", "{month}", "{day}"], id: \.self) { token in
                Button(action: {
                  customTitleFormat += token
                }) {
                  Text(token)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
              }
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        }

        Divider()

        // 2. Note Content Template
        SettingsRow(
          title: "Default Note Content",
          subtitle: "Initial Markdown template inserted into newly created notes"
        ) {
          Picker("", selection: $contentPreset) {
            ForEach(NoteTemplateEngine.ContentTemplatePreset.allCases) { preset in
              Text(preset.displayName).tag(preset.rawValue)
            }
          }
          .frame(width: 170)
        }

        if contentPreset == NoteTemplateEngine.ContentTemplatePreset.custom.rawValue {
          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Custom Markdown Content Template:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
              Spacer()

              HStack(spacing: 4) {
                Text("Insert:")
                  .font(.system(size: 10))
                  .foregroundColor(.secondary)
                ForEach(["{{title}}", "{{date}}", "{{time}}"], id: \.self) { token in
                  Button(action: {
                    customContentTemplate += token
                  }) {
                    Text(token)
                      .font(.system(size: 10, design: .monospaced))
                      .padding(.horizontal, 5)
                      .padding(.vertical, 2)
                      .background(Color.secondary.opacity(0.12))
                      .cornerRadius(4)
                  }
                  .buttonStyle(.plain)
                }
              }
            }

            TextEditor(text: $customContentTemplate)
              .font(.system(size: 12, design: .monospaced))
              .frame(minHeight: 110, maxHeight: 180)
              .scrollContentBackground(.hidden)
              .padding(6)
              .background(Color(NSColor.textBackgroundColor))
              .cornerRadius(6)
              .overlay(
                RoundedRectangle(cornerRadius: 6)
                  .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
              )

            HStack {
              Text("Variables will be replaced when creating a note.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
              Spacer()
              Button("Reset to Default Template") {
                customContentTemplate =
                  NoteTemplateEngine.ContentTemplatePreset.heading.defaultTemplate
              }
              .font(.system(size: 10))
              .buttonStyle(.plain)
              .foregroundColor(.accentColor)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
        }

        Divider()

        SettingsRow(
          title: "Start MCP Server at Launch",
          subtitle: "Automatically launch local HTTP/SSE server for AI connections"
        ) {
          Toggle("", isOn: $mcpAutostart)
            .toggleStyle(.switch)
        }
      }

      SettingsCard(
        title: "Auto-Save & Synchronization",
        footer:
          "Brain.md periodically persists notes and keeps vaults in sync with external editors."
      ) {
        SettingsRow(
          title: "Auto-Save Delay",
          subtitle: "Time to wait after typing before automatically saving changes to disk"
        ) {
          Picker("", selection: $autosaveDebounce) {
            Text("Instant (0.5s)").tag(0.5)
            Text("Normal (1.0s)").tag(1.0)
            Text("Relaxed (3.0s)").tag(3.0)
          }
          .frame(width: 140)
        }

        Divider()

        SettingsRow(
          title: "Background File Watcher",
          subtitle: "Detect note changes made by external tools (Obsidian, VS Code, Git)"
        ) {
          Toggle("", isOn: $fileWatcherEnabled)
            .toggleStyle(.switch)
        }
      }
    }
  }
}

// MARK: - 2. Appearance Settings Pane

public struct AppearanceSettingsPane: View {
  @AppStorage("app_color_scheme") private var appColorScheme: String = "system"
  @AppStorage("app_accent_color") private var accentColor: String = "system"
  @AppStorage("selected_dark_theme_id") private var selectedDarkThemeId: String = "github-dark"
  @AppStorage("selected_light_theme_id") private var selectedLightThemeId: String = "github-light"
  @AppStorage("custom_theme_override") private var customThemeOverride: String = "auto"
  @AppStorage("mermaid_theme_mode") private var mermaidThemeMode: String = "adaptive"
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var themeManager = ThemeManager.shared

  private var activeTheme: TerminalTheme {
    themeManager.currentTheme(for: colorScheme)
  }

  public var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "App Theme & Appearance") {
        SettingsRow(
          title: "Appearance Mode",
          subtitle: "Choose between matching system, forced dark, or light mode"
        ) {
          Picker("", selection: $appColorScheme) {
            Text("Match System").tag("system")
            Text("Dark Mode").tag("dark")
            Text("Light Mode").tag("light")
          }
          .frame(width: 150)
          .onChange(of: appColorScheme) { _, _ in
            themeManager.notifyThemeChanged()
          }
        }

        Divider()

        SettingsRow(
          title: "Active Theme Override",
          subtitle: "Force a specific theme or automatically follow dark/light preferences"
        ) {
          Picker("", selection: $customThemeOverride) {
            Text("Auto (Follow Dark/Light)").tag("auto")
            Divider()
            Section("Dark Themes (80)") {
              ForEach(TerminalThemes.families, id: \.self) { family in
                let familyThemes = TerminalThemes.dark.filter { $0.themeFamily == family }
                if !familyThemes.isEmpty {
                  Section(family) {
                    ForEach(familyThemes) { theme in
                      Text(theme.displayName).tag(theme.id)
                    }
                  }
                }
              }
            }
            Section("Light Themes (32)") {
              ForEach(TerminalThemes.families, id: \.self) { family in
                let familyThemes = TerminalThemes.light.filter { $0.themeFamily == family }
                if !familyThemes.isEmpty {
                  Section(family) {
                    ForEach(familyThemes) { theme in
                      Text(theme.displayName).tag(theme.id)
                    }
                  }
                }
              }
            }
          }
          .frame(width: 220)
          .onChange(of: customThemeOverride) { _, _ in
            themeManager.notifyThemeChanged()
          }
        }

        Divider()

        SettingsRow(
          title: "Preferred Dark Theme",
          subtitle: "Active when in dark mode (80 themes from terminalcolors.com)"
        ) {
          Picker("", selection: $selectedDarkThemeId) {
            ForEach(TerminalThemes.families, id: \.self) { family in
              let familyThemes = TerminalThemes.dark.filter { $0.themeFamily == family }
              if !familyThemes.isEmpty {
                Section(family) {
                  ForEach(familyThemes) { theme in
                    Text(theme.displayName).tag(theme.id)
                  }
                }
              }
            }
          }
          .frame(width: 220)
          .disabled(customThemeOverride != "auto")
          .onChange(of: selectedDarkThemeId) { _, _ in
            themeManager.notifyThemeChanged()
          }
        }

        Divider()

        SettingsRow(
          title: "Preferred Light Theme",
          subtitle: "Active when in light mode (32 themes from terminalcolors.com)"
        ) {
          Picker("", selection: $selectedLightThemeId) {
            ForEach(TerminalThemes.families, id: \.self) { family in
              let familyThemes = TerminalThemes.light.filter { $0.themeFamily == family }
              if !familyThemes.isEmpty {
                Section(family) {
                  ForEach(familyThemes) { theme in
                    Text(theme.displayName).tag(theme.id)
                  }
                }
              }
            }
          }
          .frame(width: 220)
          .disabled(customThemeOverride != "auto")
          .onChange(of: selectedLightThemeId) { _, _ in
            themeManager.notifyThemeChanged()
          }
        }
      }

      // Live Theme Preview Card
      SettingsCard(title: "Theme Preview: \(activeTheme.displayName)") {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
              Text(activeTheme.displayName)
                .font(.system(size: 13, weight: .bold))
              Text(
                "\(activeTheme.themeFamily) · \(activeTheme.isDark ? "Dark Theme" : "Light Theme")"
              )
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
            }
            Spacer()

            // Theme Pills (Background & Foreground)
            HStack(spacing: 6) {
              Text(activeTheme.backgroundHex)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                  RoundedRectangle(cornerRadius: 4).stroke(
                    Color.secondary.opacity(0.3), lineWidth: 1))

              Circle()
                .fill(activeTheme.background)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
            }
          }

          // Palette Swatches
          VStack(alignment: .leading, spacing: 6) {
            Text("ANSI Palette (16 Colors)")
              .font(.system(size: 10, weight: .medium))
              .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 5) {
                ForEach(Array(activeTheme.palette.enumerated()), id: \.offset) { idx, hex in
                  VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4)
                      .fill(Color(hex: hex) ?? .clear)
                      .frame(width: 22, height: 18)
                      .overlay(
                        RoundedRectangle(cornerRadius: 4)
                          .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
                      )
                    Text("\(idx)")
                      .font(.system(size: 8, design: .monospaced))
                      .foregroundColor(.secondary)
                  }
                  .help("ANSI Color \(idx): \(hex)")
                }
              }
              .padding(.vertical, 2)
            }
          }

          // Mini Syntax Preview
          let syntaxTheme = activeTheme.toSyntaxTheme()
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
              Text("struct ").foregroundStyle(syntaxTheme.keyword)
              Text("Vault ").foregroundStyle(syntaxTheme.type)
              Text("{")
            }
            HStack(spacing: 0) {
              Text("    let ").foregroundStyle(syntaxTheme.keyword)
              Text("name: ").foregroundStyle(syntaxTheme.plainText)
              Text("String ").foregroundStyle(syntaxTheme.type)
              Text("= ").foregroundStyle(syntaxTheme.keyword)
              Text("\"brain.md\"").foregroundStyle(syntaxTheme.string)
            }
            HStack(spacing: 0) {
              Text("    // High-contrast syntax highlighting").foregroundStyle(syntaxTheme.comment)
            }
            HStack(spacing: 0) {
              Text("    func ").foregroundStyle(syntaxTheme.keyword)
              Text("count").foregroundStyle(syntaxTheme.function)
              Text("() -> ")
              Text("Int ").foregroundStyle(syntaxTheme.type)
              Text("{ ")
              Text("112").foregroundStyle(syntaxTheme.number)
              Text(" }")
            }
            Text("}")
          }
          .font(.system(size: 11, design: .monospaced))
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(syntaxTheme.background)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(syntaxTheme.border.opacity(0.5), lineWidth: 1)
          )
        }
        .padding(14)
      }

      SettingsCard(title: "Diagrams & Visuals") {
        SettingsRow(
          title: "Mermaid Theme",
          subtitle: "Theme used when rendering Mermaid.js flowcharts and diagrams"
        ) {
          Picker("", selection: $mermaidThemeMode) {
            Text("Adaptive (Match Window)").tag("adaptive")
            Text("GitHub Dark").tag("dark")
            Text("GitHub Light").tag("light")
          }
          .frame(width: 180)
        }
      }
    }
  }
}

// MARK: - 3. Editor & Markdown Settings Pane

public struct EditorSettingsPane: View {
  @AppStorage("default_view_mode") private var defaultViewMode: String = "split"
  @AppStorage("preview_content_width") private var previewContentWidth: Double = 850.0
  @AppStorage("editor_font_size") private var fontSize: Double = 14.0
  @AppStorage("editor_font_design") private var fontDesign: String = "system"
  @AppStorage("editor_show_word_count") private var showWordCount: Bool = true
  @AppStorage("editor_sync_scroll") private var syncPreviewScroll: Bool = true
  @AppStorage("editor_split_ratio") private var splitRatio: Double = 0.5
  @AppStorage("syntax_theme_override") private var syntaxTheme: String = "auto"

  public var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Workspace Layout") {
        SettingsRow(
          title: "Default View Mode",
          subtitle: "Initial layout when opening a Markdown note"
        ) {
          Picker("", selection: $defaultViewMode) {
            Text("Split View (Editor + Preview)").tag("split")
            Text("Editor Only").tag("editor")
            Text("Preview Only").tag("preview")
          }
          .frame(width: 210)
        }

        Divider()

        SettingsRow(
          title: "Split View Proportion",
          subtitle: "Editor width: \(Int(splitRatio * 100))% / Preview: \(Int((1.0 - splitRatio) * 100))%"
        ) {
          HStack(spacing: 8) {
            Slider(value: $splitRatio, in: 0.20...0.80, step: 0.05)
              .frame(width: 110)
            Button("Reset") {
              withAnimation {
                splitRatio = 0.5
              }
            }
            .font(.system(size: 11))
          }
        }

        Divider()

        SettingsRow(
          title: "Synchronize Preview Scrolling",
          subtitle: "Scroll the live preview in lockstep with the Markdown editor in Split View"
        ) {
          Toggle("", isOn: $syncPreviewScroll)
            .toggleStyle(.switch)
        }

        Divider()

        SettingsRow(
          title: "Preview Content Width",
          subtitle: previewContentWidth >= 2000
            ? "Full width (unconstrained)" : "Maximum reading width: \(Int(previewContentWidth)) pt"
        ) {
          HStack(spacing: 6) {
            Slider(value: $previewContentWidth, in: 400...2000, step: 25)
              .frame(width: 120)

            TextField(
              "Width",
              value: Binding<Int>(
                get: { Int(previewContentWidth) },
                set: { previewContentWidth = Double($0) }
              ), format: .number.grouping(.never)
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .multilineTextAlignment(.trailing)

            Text("pt")
              .font(.system(size: 11))
              .foregroundColor(.secondary)
          }
        }

        Divider()

        SettingsRow(
          title: "Word & Character Counter",
          subtitle: "Show real-time statistics in the editor header"
        ) {
          Toggle("", isOn: $showWordCount)
            .toggleStyle(.switch)
        }
      }

      SettingsCard(title: "Typography & Syntax Highlighting") {
        SettingsRow(
          title: "Editor Font Size",
          subtitle: "\(Int(fontSize)) pt"
        ) {
          HStack(spacing: 8) {
            Slider(value: $fontSize, in: 11...24, step: 1)
              .frame(width: 120)
            Text("\(Int(fontSize)) pt")
              .font(.system(size: 12, design: .monospaced))
              .frame(width: 36, alignment: .trailing)
          }
        }

        Divider()

        SettingsRow(
          title: "Font Family",
          subtitle: "Typeface family applied to the markdown editor"
        ) {
          Picker("", selection: $fontDesign) {
            Text("System (San Francisco)").tag("system")
            Text("Monospaced (SF Mono)").tag("monospaced")
            Text("Rounded").tag("rounded")
            Text("Serif (New York)").tag("serif")
          }
          .frame(width: 180)
        }

        Divider()

        SettingsRow(
          title: "Code Syntax Highlighting",
          subtitle: "Syntax color theme for fenced code blocks"
        ) {
          Picker("", selection: $syntaxTheme) {
            Text("Follow App Theme (Recommended)").tag("auto")
            Text("GitHub Dark").tag("githubDark")
            Text("GitHub Light").tag("githubLight")
          }
          .frame(width: 220)
        }
      }
    }
  }
}

// MARK: - 4. MCP Server Settings Pane

public struct MCPServerSettingsPane: View {
  @ObservedObject var server = MCPHTTPServer.shared
  @AppStorage("mcp_preferred_port") private var preferredPort: Int = 8765
  @AppStorage("mcp_read_only") private var readOnlyMode: Bool = false
  @State private var copiedConfig = false

  public var body: some View {
    VStack(spacing: 16) {
      // Live Status Card
      SettingsCard(title: "Server Status") {
        SettingsRow(
          title: "Model Context Protocol",
          subtitle: server.isRunning
            ? "Listening on port \(server.port) (HTTP / SSE)" : "Server is stopped"
        ) {
          HStack(spacing: 8) {
            Circle()
              .fill(server.isRunning ? Color.green : Color.red)
              .frame(width: 9, height: 9)

            Text(server.isRunning ? "ACTIVE" : "INACTIVE")
              .font(.system(size: 11, weight: .bold, design: .monospaced))
              .foregroundColor(server.isRunning ? .green : .red)

            Button(action: restartServer) {
              Text("Restart")
                .font(.system(size: 11))
            }
          }
        }

        Divider()

        SettingsRow(
          title: "Preferred Port",
          subtitle: "Default local port for incoming AI agent connections"
        ) {
          HStack(spacing: 6) {
            TextField("Port", value: $preferredPort, format: .number.grouping(.never))
              .textFieldStyle(.roundedBorder)
              .frame(width: 80)
              .multilineTextAlignment(.trailing)
          }
        }

        Divider()

        SettingsRow(
          title: "Read-Only Security Guard",
          subtitle: "Prevent external agents from modifying or deleting vault notes"
        ) {
          Toggle("", isOn: $readOnlyMode)
            .toggleStyle(.switch)
        }
      }

      // Client Integration Card
      SettingsCard(
        title: "Claude Desktop & Agent Configuration",
        footer:
          "Add this configuration block to claude_desktop_config.json to connect Claude directly."
      ) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Stdio Command Configuration")
              .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(action: copyClaudeConfig) {
              Label(
                copiedConfig ? "Copied!" : "Copy JSON",
                systemImage: copiedConfig ? "checkmark" : "doc.on.doc"
              )
              .font(.system(size: 11))
            }
          }

          Text(configJSON)
            .font(.system(size: 11, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
            .cornerRadius(6)
        }
        .padding(14)
      }
    }
  }

  private var configJSON: String {
    """
    {
      "mcpServers": {
        "brain-md": {
          "command": "\(Bundle.main.executablePath ?? "/path/to/brain-md")",
          "args": ["--stdio"]
        }
      }
    }
    """
  }

  private func copyClaudeConfig() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(configJSON, forType: .string)
    withAnimation { copiedConfig = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { copiedConfig = false }
    }
  }

  private func restartServer() {
    server.start(preferredPort: UInt16(preferredPort))
  }
}

// MARK: - 5. Vault & Storage Settings Pane

public struct VaultSettingsPane: View {
  @ObservedObject var vault: VaultManager
  @AppStorage("attachment_folder") private var attachmentFolder: String = "Attachments"
  @State private var showingReseedConfirmation = false
  @State private var reseedSuccess = false

  public var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Active Notes Vault") {
        SettingsRow(
          title: "Vault Location",
          subtitle: vault.vaultURL.path
        ) {
          HStack(spacing: 8) {
            Button("Change...") {
              chooseVaultFolder()
            }

            Button("Reveal in Finder") {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vault.vaultURL.path)
            }
          }
        }

        Divider()

        SettingsRow(
          title: "Total Notes",
          subtitle: "\(vault.totalNotesCount) Markdown documents currently indexed"
        ) {
          Button(action: { vault.refreshFiles() }) {
            Label("Rescan Vault", systemImage: "arrow.clockwise")
              .font(.system(size: 11))
          }
        }
      }

      SettingsCard(
        title: "Attachments & Media",
        footer:
          "Pasted or dropped pictures will be automatically saved into this folder and linked in your note. Clear this to store pictures in the same folder as the active note."
      ) {
        SettingsRow(
          title: "Attachment Folder",
          subtitle: attachmentFolder.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Store images in the same folder as the note"
            : "Store in '/\(attachmentFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/")))' within vault"
        ) {
          HStack(spacing: 8) {
            TextField("Attachments", text: $attachmentFolder)
              .textFieldStyle(.roundedBorder)
              .frame(width: 140)

            if !attachmentFolder.trimmingCharacters(in: .whitespaces).isEmpty {
              Button("Reset") {
                attachmentFolder = "Attachments"
              }
              .font(.system(size: 11))
            }
          }
        }
      }

      SettingsCard(
        title: "Starter Notes",
        footer:
          "Seed default introductory notes explaining MCP integration and Mermaid architecture."
      ) {
        SettingsRow(
          title: "Re-seed Starter Notes",
          subtitle: "Restore 'Welcome to Brain-md.md' and 'Project Ideas.md'"
        ) {
          Button(action: { showingReseedConfirmation = true }) {
            Text(reseedSuccess ? "Restored!" : "Restore Notes")
              .foregroundColor(reseedSuccess ? .green : .primary)
          }
          .confirmationDialog("Restore Starter Notes?", isPresented: $showingReseedConfirmation) {
            Button("Restore Starter Notes") {
              seedStarterNotes()
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text("This will ensure default starter notes are present in your vault folder.")
          }
        }
      }
    }
  }

  private func chooseVaultFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select Vault Folder"
    panel.directoryURL = vault.vaultURL

    if panel.runModal() == .OK, let selectedURL = panel.url {
      vault.setVaultURL(selectedURL)
    }
  }

  private func seedStarterNotes() {
    try? vault.createFile(
      relativePath: "Welcome to Brain-md.md", content: VaultManager.defaultWelcomeNoteContent)
    try? vault.createFile(
      relativePath: "Project Ideas.md", content: VaultManager.defaultIdeasNoteContent)
    withAnimation { reseedSuccess = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { reseedSuccess = false }
    }
  }
}

// MARK: - 6. Advanced Settings Pane

public struct AdvancedSettingsPane: View {
  @AppStorage("log_level") private var logLevel: String = "info"
  @State private var cachesCleared = false
  @State private var showingResetConfirmation = false

  public var body: some View {
    VStack(spacing: 16) {
      SettingsCard(title: "Performance & Caches") {
        SettingsRow(
          title: "Clear Memory Caches",
          subtitle: "Flush in-memory syntax highlighting, AST documents, and Mermaid templates"
        ) {
          Button(action: clearCaches) {
            Text(cachesCleared ? "Cleared!" : "Clear Caches")
              .foregroundColor(cachesCleared ? .green : .primary)
          }
        }

        Divider()

        SettingsRow(
          title: "Diagnostic Log Level",
          subtitle: "Control stdout and stderr verbosity for MCP and file watcher"
        ) {
          Picker("", selection: $logLevel) {
            Text("Error Only").tag("error")
            Text("Info (Default)").tag("info")
            Text("Verbose Debug").tag("debug")
          }
          .frame(width: 140)
        }
      }

      SettingsCard(title: "Reset", footer: "Restores all user settings to their default values.") {
        SettingsRow(
          title: "Reset All Settings",
          subtitle: "Clear saved appearance, editor, and server preferences"
        ) {
          Button("Reset Preferences...", role: .destructive) {
            showingResetConfirmation = true
          }
          .confirmationDialog("Reset All Preferences?", isPresented: $showingResetConfirmation) {
            Button("Reset to Defaults", role: .destructive) {
              resetAllPreferences()
            }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(
              "This will reset your preferences to default settings. Notes in your vault will not be affected."
            )
          }
        }
      }
    }
  }

  private func clearCaches() {
    // Trigger cache clearing
    withAnimation { cachesCleared = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      withAnimation { cachesCleared = false }
    }
  }

  private func resetAllPreferences() {
    let domain = Bundle.main.bundleIdentifier ?? "itsreidar.brain-md"
    UserDefaults.standard.removePersistentDomain(forName: domain)
  }
}

// MARK: - 7. About Settings Pane

public struct AboutSettingsPane: View {
  public var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 10) {
        if let appIcon = Bundle.main.image(forResource: "brain-md") ?? NSImage(named: "brain-md") ?? NSImage(named: "NSApplicationIcon") {
          Image(nsImage: appIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
        } else {
          Image(systemName: "brain.head.profile")
            .font(.system(size: 52))
            .foregroundStyle(
              LinearGradient(
                colors: [.blue, .purple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
        }

        Text("Brain.md")
          .font(.system(size: 22, weight: .bold, design: .rounded))

        Text("Version 1.0 (Build 1)")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 10)

      SettingsCard(title: "About Application") {
        SettingsRow(
          title: "Native Architecture",
          subtitle: "100% native Swift 6, AppKit, and SwiftUI on Apple Silicon"
        ) {
          Image(systemName: "apple.logo")
            .foregroundColor(.secondary)
        }

        Divider()

        SettingsRow(
          title: "Model Context Protocol",
          subtitle: "Built-in JSON-RPC 2.0 server supporting stdio and SSE transport"
        ) {
          Text("MCP v1.0")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.purple)
        }

        Divider()

        SettingsRow(
          title: "Source Code & Contributions",
          subtitle: "Open source on GitHub"
        ) {
          Button("GitHub") {
            if let url = URL(string: "https://github.com") {
              NSWorkspace.shared.open(url)
            }
          }
        }

        Divider()

        SettingsRow(
          title: "License",
          subtitle: "GNU General Public License v3.0"
        ) {
          Text("GPLv3")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
        }
      }
    }
  }
}

// MARK: - 8. Local AI & Voice Settings Pane

public struct LocalAISettingsPane: View {
  @ObservedObject var modelManager = LocalModelManager.shared
  @AppStorage(LocalModelManager.enabledDefaultsKey) private var isAIEnabled = false
  @AppStorage("ai_capture_system_audio") private var captureSystemAudio: Bool = true
  @AppStorage("ai_capture_microphone") private var captureMicrophone: Bool = true
  @AppStorage("ai_capture_screen_diagrams") private var captureScreenDiagrams: Bool = true
  @State private var pendingDeletionBytes: Int64?
  @AppStorage(MeetingTranscriber.localeDefaultsKey) private var transcriptionLocale = ""
  @State private var transcriptionLocales: [String] = []

  public init() {}

  public var body: some View {
    VStack(spacing: 20) {
      SettingsCard(
        title: "On-Device AI",
        footer: "Gemma 4 E4B (4-bit, quantization-aware trained) runs on this Mac with MLX on Apple Silicon. "
          + "It downloads once from Hugging Face; after that, notes never leave your Mac."
      ) {
        SettingsRow(
          title: "Enable on-device AI",
          subtitle: "Summaries, action items, rewriting and screen explanations with Gemma 4",
          icon: "cpu"
        ) {
          Toggle("", isOn: Binding(get: { isAIEnabled }, set: setAIEnabled))
            .toggleStyle(.switch)
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("mlx-community/gemma-4-E4B-it-qat-4bit")
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            Spacer()
            statusBadge
          }
          modelDetails
        }
        .padding(16)
      }
      .confirmationDialog(
        "Delete the Gemma 4 model files?",
        isPresented: Binding(get: { pendingDeletionBytes != nil }, set: { if !$0 { pendingDeletionBytes = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete \(Self.format(pendingDeletionBytes ?? 0))", role: .destructive) {
          modelManager.removeModelCache()
          pendingDeletionBytes = nil
        }
        Button("Keep Files", role: .cancel) { pendingDeletionBytes = nil }
      } message: {
        Text("Keeping them lets you turn on-device AI back on without downloading again.")
      }
      .onAppear(perform: resumeDownloadIfNeeded)

      // 2. Audio & Visual Capture Permissions & Settings
      SettingsCard(title: "Meeting Audio & Visual Capture") {
        SettingsRow(
          title: "Capture Incoming System Audio",
          subtitle: "Transcribes remote participants and meeting calls using ScreenCaptureKit",
          icon: "speaker.wave.3.fill"
        ) {
          Toggle("", isOn: $captureSystemAudio)
            .toggleStyle(.switch)
        }

        Divider()

        SettingsRow(
          title: "Capture Microphone Audio",
          subtitle: "Transcribes local room voice and speaker questions via microphone",
          icon: "mic.fill"
        ) {
          Toggle("", isOn: $captureMicrophone)
            .toggleStyle(.switch)
        }

        Divider()

        SettingsRow(
          title: "Transcription Language",
          subtitle: "Meetings are transcribed on this Mac; each language's speech model downloads once",
          icon: "character.bubble"
        ) {
          Picker("", selection: $transcriptionLocale) {
            Text("System (\(Self.languageName(Locale.current.identifier)))").tag("")
            ForEach(transcriptionLocales, id: \.self) { identifier in
              Text(Self.languageName(identifier)).tag(identifier)
            }
          }
          .labelsHidden()
          .frame(width: 220)
          .task {
            transcriptionLocales = await SpeechTranscriber.supportedLocales
              .map(\.identifier)
              .sorted { Self.languageName($0) < Self.languageName($1) }
          }
        }

        Divider()

        SettingsRow(
          title: "Visual Diagram Comprehension",
          subtitle: "Captures on-screen presentation slides and architectural diagrams for notes",
          icon: "rectangle.inset.filled.and.cursorarrow"
        ) {
          Toggle("", isOn: $captureScreenDiagrams)
            .toggleStyle(.switch)
        }
      }
    }
  }

  private func setAIEnabled(_ enabled: Bool) {
    isAIEnabled = enabled
    if enabled {
      resumeDownloadIfNeeded()
    } else {
      modelManager.cancelDownload()
      modelManager.unloadModel()
      let bytes = modelManager.diskUsageBytes()
      if bytes > 0 { pendingDeletionBytes = bytes }
    }
  }

  /// Enabled but not installed (first enable, or a download interrupted by quitting): fetch it.
  private func resumeDownloadIfNeeded() {
    guard isAIEnabled, modelManager.state.status == .notDownloaded else { return }
    modelManager.startDownload()
  }

  private static func languageName(_ identifier: String) -> String {
    Locale.current.localizedString(forIdentifier: identifier) ?? identifier
  }

  private static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  @ViewBuilder
  private var modelDetails: some View {
    let state = modelManager.state
    switch state.status {
    case .notDownloaded:
      Text(isAIEnabled ? "Preparing download…" : "Not downloaded. Turning on-device AI on downloads the model.")
        .font(.system(size: 12))
        .foregroundColor(.secondary)
    case .downloading:
      ProgressView(value: state.progress)
        .progressViewStyle(.linear)
      HStack {
        Text(state.totalBytes > 0
          ? "\(Self.format(state.bytesDownloaded)) of \(Self.format(state.totalBytes)) (\(Int(state.progress * 100))%)"
          : "Contacting Hugging Face…")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundColor(.secondary)
        Spacer()
        Button("Cancel") { setAIEnabled(false) }
          .buttonStyle(.bordered)
      }
    case .ready:
      HStack {
        Label("Installed · \(Self.format(state.totalBytes)) on disk", systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)
        Spacer()
        Button("Delete Model Files…", role: .destructive) {
          pendingDeletionBytes = modelManager.diskUsageBytes()
        }
        .buttonStyle(.bordered)
      }
    case .error:
      HStack(alignment: .top) {
        Text(state.errorMessage ?? "The download failed.")
          .font(.system(size: 12))
          .foregroundColor(.red)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Retry") {
          modelManager.checkExistingModel() // clears the error, keeps already-downloaded files
          modelManager.startDownload()
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    let (label, icon, color): (String, String, Color) = switch modelManager.state.status {
    case .notDownloaded: ("Not Installed", "arrow.down.circle", .secondary)
    case .downloading: ("Downloading \(Int(modelManager.state.progress * 100))%", "arrow.down.circle.fill", .accentColor)
    case .ready: (modelManager.isLoaded ? "Loaded" : "Ready", "checkmark.circle.fill", .green)
    case .error: ("Download Failed", "exclamationmark.triangle.fill", .red)
    }
    Label(label, systemImage: icon)
      .font(.system(size: 11, weight: .semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15))
      .foregroundColor(color)
      .clipShape(Capsule())
  }
}

