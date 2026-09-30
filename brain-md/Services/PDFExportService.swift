//
//  PDFExportService.swift
//  brain-md
//
//  Asynchronous vector PDF export engine for Markdown previews using WebKit.
//

import AppKit
import Foundation
import WebKit

public enum PDFExportError: LocalizedError {
    case navigationFailed(String)
    case generationTimeout
    case invalidPDFData
    
    public var errorDescription: String? {
        switch self {
        case .navigationFailed(let reason):
            return "Web preview failed to render: \(reason)"
        case .generationTimeout:
            return "PDF export timed out after waiting for content to render."
        case .invalidPDFData:
            return "Failed to produce valid PDF data from preview."
        }
    }
}

/// Service that coordinates rendering and exporting markdown preview content to PDF
@MainActor
public final class PDFExportService: NSObject, WKNavigationDelegate {
    public static let shared = PDFExportService()
    
    // Hold an active task and webView to retain memory during async generation
    private var activeWebView: WKWebView?
    private var completionContinuation: CheckedContinuation<Data, Error>?
    private var timeoutTask: Task<Void, Never>?
    
    private override init() {
        super.init()
    }
    
    /// Generates vector PDF data from the given markdown content and terminal theme
    public func generatePDFData(
        markdown: String,
        theme: TerminalTheme? = nil,
        contentWidth: Double = 850
    ) async throws -> Data {
        // Cancel any pending operation
        cleanup()
        
        let activeTheme = theme ?? ThemeManager.shared.currentTheme
        let html = MarkdownHTMLRenderer.renderHTML(
            markdown: markdown,
            theme: activeTheme,
            contentWidth: contentWidth
        )
        
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: 1000), configuration: config)
        self.activeWebView = webView
        webView.navigationDelegate = self
        
        return try await withCheckedThrowingContinuation { continuation in
            self.completionContinuation = continuation
            
            // Set 15-second timeout to prevent indefinite hangs
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.handleTimeout()
            }
            
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }
    
    /// Exports the rendered markdown preview directly to a destination file URL
    public func exportPDF(
        markdown: String,
        theme: TerminalTheme? = nil,
        to destinationURL: URL,
        contentWidth: Double = 850
    ) async throws {
        let pdfData = try await generatePDFData(markdown: markdown, theme: theme, contentWidth: contentWidth)
        try pdfData.write(to: destinationURL, options: .atomic)
    }
    
    // MARK: - WKNavigationDelegate
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give Mermaid or MathJax a brief moment to finish any DOM layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak webView] in
            guard let self = self, let webView = webView else { return }
            
            webView.evaluateJavaScript(
                "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, 600)"
            ) { [weak self, weak webView] result, _ in
                guard let self = self, let webView = webView else { return }
                
                let rawHeight = (result as? NSNumber)?.doubleValue ?? 1000.0
                let totalHeight = CGFloat(max(600.0, min(rawHeight + 60.0, 100_000.0)))
                let totalWidth = webView.frame.width
                
                let pdfConfig = WKPDFConfiguration()
                pdfConfig.rect = CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
                
                webView.createPDF(configuration: pdfConfig) { [weak self] pdfResult in
                    guard let self = self else { return }
                    
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                    
                    switch pdfResult {
                    case .success(let data):
                        if data.isEmpty {
                            self.completionContinuation?.resume(throwing: PDFExportError.invalidPDFData)
                        } else {
                            self.completionContinuation?.resume(returning: data)
                        }
                    case .failure(let err):
                        self.completionContinuation?.resume(throwing: err)
                    }
                    self.completionContinuation = nil
                    self.cleanup()
                }
            }
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        completionContinuation?.resume(throwing: PDFExportError.navigationFailed(error.localizedDescription))
        completionContinuation = nil
        cleanup()
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        completionContinuation?.resume(throwing: PDFExportError.navigationFailed(error.localizedDescription))
        completionContinuation = nil
        cleanup()
    }
    
    // MARK: - Cleanup & Timeout
    
    private func handleTimeout() {
        timeoutTask = nil
        completionContinuation?.resume(throwing: PDFExportError.generationTimeout)
        completionContinuation = nil
        cleanup()
    }
    
    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil
        activeWebView?.navigationDelegate = nil
        activeWebView?.stopLoading()
        activeWebView = nil
    }
}
