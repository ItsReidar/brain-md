//
//  MermaidDiagramView.swift
//  brain-md
//

import SwiftUI
import WebKit
import AppKit

// MARK: - Mermaid Script Provider

public enum MermaidScriptProvider: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedScript: String?
    
    public static func getScriptURL() -> URL? {
        // 1. Try App Bundle resources
        if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
            return url
        }
        
        // 2. Try class/module bundle
        let allBundles = Bundle.allBundles + Bundle.allFrameworks
        for bundle in allBundles {
            if let url = bundle.url(forResource: "mermaid.min", withExtension: "js") {
                return url
            }
        }
        
        // 3. Try filesystem search paths (useful during local tests & dev)
        let fallbackPaths = [
            "brain-md/Resources/mermaid.min.js",
            "Resources/mermaid.min.js",
            "../Resources/mermaid.min.js",
            "../../brain-md/Resources/mermaid.min.js"
        ]
        let currentPath = FileManager.default.currentDirectoryPath
        for relPath in fallbackPaths {
            let fullURL = URL(fileURLWithPath: (currentPath as NSString).appendingPathComponent(relPath))
            if FileManager.default.fileExists(atPath: fullURL.path) {
                return fullURL
            }
        }
        
        return nil
    }
    
    public static func getScript() -> String {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cachedScript {
            return cached
        }
        
        if let url = getScriptURL(),
           let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
            cachedScript = content
            return content
        }
        
        return ""
    }
}

// MARK: - HTML Template Generator

public enum MermaidHTMLTemplate {
    private static let cachedHTML: String = generateTemplate()
    
    public static func generate() -> String {
        cachedHTML
    }
    
    private static func generateTemplate() -> String {
        let scriptTag: String
        if let scriptURL = MermaidScriptProvider.getScriptURL() {
            // Stream directly via file URL or bundle resource without allocating 3.5MB in Swift RAM
            scriptTag = "<script src=\"\(scriptURL.absoluteString)\"></script>"
        } else {
            scriptTag = "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>"
        }
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
          }
          html, body {
            background-color: transparent !important;
            width: 100%;
            height: auto;
            overflow: hidden;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: flex-start;
          }
          #root {
            width: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
            padding: 16px;
          }
          #container {
            display: flex;
            justify-content: center;
            align-items: center;
            width: 100%;
            transform-origin: top center;
            transition: transform 0.15s ease-out;
          }
          svg {
            max-width: 100% !important;
            height: auto !important;
            display: block;
            margin: 0 auto;
          }
        </style>
        \(scriptTag)
        </head>
        <body>
        <div id="root">
          <div id="container"></div>
        </div>
        <script>
        let currentRenderId = 0;

        window.renderMermaid = async function(rawCode, isDark, zoom) {
          const renderId = ++currentRenderId;
          const container = document.getElementById('container');
          
          try {
            if (typeof mermaid === 'undefined') {
              throw new Error("Mermaid library is loading or unavailable.");
            }
            
            mermaid.initialize({
              startOnLoad: false,
              suppressErrorRendering: true,
              theme: isDark ? 'dark' : 'default',
              securityLevel: 'loose',
              fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif'
            });
            
            const uniqueId = 'mermaid_' + Math.random().toString(36).substring(2, 9);
            const { svg } = await mermaid.render(uniqueId, rawCode);
            
            if (renderId !== currentRenderId) return;
            
            container.innerHTML = svg;
            container.style.transform = zoom && zoom !== 1 ? `scale(${zoom})` : 'none';
            
            // Measure layout after DOM update
            requestAnimationFrame(() => {
              const svgEl = container.querySelector('svg');
              let height = document.body.scrollHeight;
              if (svgEl) {
                const rect = svgEl.getBoundingClientRect();
                height = Math.max(height, Math.ceil((rect.height * (zoom || 1.0)) + 32));
              }
              
              window.webkit.messageHandlers.mermaidHandler.postMessage({
                type: 'rendered',
                height: Math.max(height, 80),
                svg: svg
              });
            });
          } catch (err) {
            if (renderId !== currentRenderId) return;
            const message = err && (err.message || String(err)) || "Unknown Mermaid rendering error";
            
            window.webkit.messageHandlers.mermaidHandler.postMessage({
              type: 'error',
              message: message,
              height: 100
            });
          }
        };
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - Mermaid WebView Representable

public struct MermaidWebView: NSViewRepresentable {
    let code: String
    let isDarkMode: Bool
    let zoomScale: CGFloat
    @Binding var dynamicHeight: CGFloat
    @Binding var errorMessage: String?
    @Binding var svgContent: String?
    
    public init(
        code: String,
        isDarkMode: Bool,
        zoomScale: CGFloat,
        dynamicHeight: Binding<CGFloat>,
        errorMessage: Binding<String?>,
        svgContent: Binding<String?>
    ) {
        self.code = code
        self.isDarkMode = isDarkMode
        self.zoomScale = zoomScale
        self._dynamicHeight = dynamicHeight
        self._errorMessage = errorMessage
        self._svgContent = svgContent
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "mermaidHandler")
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        let html = MermaidHTMLTemplate.generate()
        let baseURL = MermaidScriptProvider.getScriptURL()?.deletingLastPathComponent() ?? Bundle.main.resourceURL
        webView.loadHTMLString(html, baseURL: baseURL)
        
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        
        if context.coordinator.isPageLoaded {
            if context.coordinator.lastCode != code ||
               context.coordinator.lastIsDark != isDarkMode ||
               context.coordinator.lastZoom != zoomScale {
                context.coordinator.triggerRender(webView: nsView, code: code, isDark: isDarkMode, zoom: zoomScale)
            }
        }
    }
    
    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidHandler")
        nsView.navigationDelegate = nil
        nsView.stopLoading()
    }
    
    public class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MermaidWebView
        var isPageLoaded = false
        var lastCode: String?
        var lastIsDark: Bool?
        var lastZoom: CGFloat?
        
        init(_ parent: MermaidWebView) {
            self.parent = parent
        }
        
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            triggerRender(webView: webView, code: parent.code, isDark: parent.isDarkMode, zoom: parent.zoomScale)
        }
        
        public func triggerRender(webView: WKWebView, code: String, isDark: Bool, zoom: CGFloat) {
            lastCode = code
            lastIsDark = isDark
            lastZoom = zoom
            
            guard let jsonData = try? JSONEncoder().encode(code),
                  let encodedCode = String(data: jsonData, encoding: .utf8) else { return }
            
            let script = "window.renderMermaid(\(encodedCode), \(isDark ? "true" : "false"), \(zoom));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "mermaidHandler",
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if type == "rendered" {
                    if let height = dict["height"] as? CGFloat, height > 30 {
                        self.parent.dynamicHeight = max(height, 80)
                    }
                    if let svg = dict["svg"] as? String {
                        self.parent.svgContent = svg
                    }
                    self.parent.errorMessage = nil
                } else if type == "error" {
                    let msg = dict["message"] as? String ?? "Mermaid syntax error"
                    self.parent.errorMessage = msg
                    self.parent.dynamicHeight = 120
                }
            }
        }
    }
}

// MARK: - Mermaid Diagram View

public struct MermaidDiagramView: View {
    public enum ViewTab: String, CaseIterable, Sendable {
        case diagram = "Diagram"
        case code = "Code"
    }
    
    @Environment(\.colorScheme) private var colorScheme
    let code: String
    
    @State private var selectedTab: ViewTab = .diagram
    @State private var dynamicHeight: CGFloat = 220
    @State private var errorMessage: String? = nil
    @State private var svgContent: String? = nil
    @State private var zoomScale: CGFloat = 1.0
    @State private var isCopiedCode: Bool = false
    @State private var isCopiedSVG: Bool = false
    
    public init(code: String) {
        self.code = code
    }
    
    private var detectedDiagramType: String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("graph") || trimmed.hasPrefix("flowchart") { return "Flowchart" }
        if trimmed.hasPrefix("sequencediagram") { return "Sequence" }
        if trimmed.hasPrefix("classdiagram") { return "Class" }
        if trimmed.hasPrefix("statediagram") { return "State" }
        if trimmed.hasPrefix("erdiagram") { return "ER Diagram" }
        if trimmed.hasPrefix("gantt") { return "Gantt" }
        if trimmed.hasPrefix("pie") { return "Pie Chart" }
        if trimmed.hasPrefix("gitgraph") { return "Git Graph" }
        if trimmed.hasPrefix("mindmap") { return "Mindmap" }
        if trimmed.hasPrefix("timeline") { return "Timeline" }
        if trimmed.hasPrefix("quadrantchart") { return "Quadrant" }
        return "Mermaid"
    }
    
    public var body: some View {
        let isDark = colorScheme == .dark
        let theme = SyntaxTheme.theme(for: colorScheme)
        
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 10) {
                // Title and Diagram Type Badge
                HStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.accentColor)
                    
                    Text("MERMAID")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(isDark ? Color(hex: "#8b949e")! : Color(hex: "#57606a")!)
                    
                    Text(detectedDiagramType)
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                }
                
                Spacer()
                
                // Tab Switcher (Diagram vs Code)
                HStack(spacing: 2) {
                    ForEach(ViewTab.allCases, id: \.self) { tab in
                        Button(action: { selectedTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(selectedTab == tab ? .primary : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(selectedTab == tab ? (isDark ? Color(hex: "#30363d")! : Color.white) : Color.clear)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(isDark ? Color(hex: "#21262d")! : Color(hex: "#eaeef2")!)
                .cornerRadius(5)
                
                // Zoom controls (only active in Diagram tab)
                if selectedTab == .diagram {
                    HStack(spacing: 4) {
                        Button(action: { zoomScale = max(0.5, zoomScale - 0.15) }) {
                            Image(systemName: "minus")
                                .font(.system(size: 10))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Zoom out")
                        
                        Text("\(Int(zoomScale * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 32)
                            .onTapGesture { zoomScale = 1.0 }
                            .help("Click to reset zoom (100%)")
                        
                        Button(action: { zoomScale = min(2.5, zoomScale + 0.15) }) {
                            Image(systemName: "plus")
                                .font(.system(size: 10))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Zoom in")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isDark ? Color(hex: "#21262d")! : Color(hex: "#eaeef2")!)
                    .cornerRadius(4)
                }
                
                // Copy Actions
                if selectedTab == .diagram && svgContent != nil {
                    Button(action: copySVG) {
                        HStack(spacing: 4) {
                            Image(systemName: isCopiedSVG ? "checkmark" : "doc.badge.arrow.up")
                                .font(.system(size: 10.5))
                            Text(isCopiedSVG ? "SVG Copied" : "Copy SVG")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundColor(isCopiedSVG ? Color.green : (isDark ? Color(hex: "#c9d1d9")! : Color(hex: "#57606a")!))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isDark ? Color(hex: "#21262d")! : Color(hex: "#eaeef2")!)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: copyCode) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopiedCode ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5))
                        Text(isCopiedCode ? "Copied" : "Copy")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(isCopiedCode ? Color.green : (isDark ? Color(hex: "#c9d1d9")! : Color(hex: "#57606a")!))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isDark ? Color(hex: "#21262d")! : Color(hex: "#eaeef2")!)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.headerBackground)
            
            Divider()
                .background(theme.border)
            
            // Content Area
            if selectedTab == .diagram {
                VStack(spacing: 0) {
                    // Error Callout Banner if syntax is invalid
                    if let error = errorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#cf222e")!)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Mermaid Syntax Error")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(Color(hex: "#cf222e")!)
                                
                                Text(error)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(4)
                            }
                            
                            Spacer()
                            
                            Button("Edit Code") {
                                selectedTab = .code
                            }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: "#cf222e")!)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .background(Color(hex: "#cf222e")!.opacity(0.08))
                        .overlay(
                            Rectangle()
                                .frame(height: 1)
                                .foregroundColor(Color(hex: "#cf222e")!.opacity(0.2)),
                            alignment: .bottom
                        )
                    }
                    
                    // Rendered Diagram WebView
                    MermaidWebView(
                        code: code,
                        isDarkMode: isDark,
                        zoomScale: zoomScale,
                        dynamicHeight: $dynamicHeight,
                        errorMessage: $errorMessage,
                        svgContent: $svgContent
                    )
                    .frame(height: dynamicHeight)
                    .frame(maxWidth: .infinity)
                    .background(isDark ? Color(hex: "#161b22")! : Color(hex: "#ffffff")!)
                }
            } else {
                // Code View with Syntax Highlighting
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(SyntaxHighlighter.highlight(code: code, language: .mermaid, theme: theme))
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(theme.background)
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.border, lineWidth: 1)
        )
    }
    
    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        withAnimation {
            isCopiedCode = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopiedCode = false
            }
        }
    }
    
    private func copySVG() {
        guard let svg = svgContent else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(svg, forType: .string)
        withAnimation {
            isCopiedSVG = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopiedSVG = false
            }
        }
    }
}
