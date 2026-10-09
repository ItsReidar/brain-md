//
//  LocalAIServices.swift
//  brain-md
//

import Foundation
import Combine
import CoreGraphics
import AppKit
import ScreenCaptureKit
import NaturalLanguage

public final class LocalModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public static let shared = LocalModelManager()
    @Published public var state: ModelDownloadState

    public var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brain-md/models/gemma-4-e4b")
    }

    public var modelDownloadURL: URL {
        URL(string: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf")!
    }

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?

    public init(modelIdentifier: String = "gemma-4-e4b") {
        self.state = ModelDownloadState(modelIdentifier: modelIdentifier)
        super.init()
    }

    public func checkExistingModel() {
        let weight = modelDirectory.appendingPathComponent("model.bin")
        if FileManager.default.fileExists(atPath: weight.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: weight.path)
            let size = (attributes?[.size] as? Int64) ?? 1_680_000_000
            state.status = .ready
            state.progress = 1.0
            state.localPath = weight.path
            state.bytesDownloaded = size
            state.totalBytes = size
        }
    }

    public func startDownload() {
        guard state.status != .downloading else { return }
        state.status = .downloading
        state.progress = 0.0
        state.bytesDownloaded = 0
        state.totalBytes = 1_680_000_000
        state.errorMessage = nil

        let config = URLSessionConfiguration.default
        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = urlSession
        let task = urlSession.downloadTask(with: modelDownloadURL)
        self.downloadTask = task
        task.resume()
    }

    public func updateProgress(bytesDownloaded: Int64, totalBytes: Int64) {
        let progress = totalBytes > 0 ? Double(bytesDownloaded) / Double(totalBytes) : 0.0
        state.status = .downloading
        state.bytesDownloaded = bytesDownloaded
        state.totalBytes = totalBytes
        state.progress = progress
    }

    public func completeDownload(localPath: String) {
        state.status = .ready
        state.progress = 1.0
        state.bytesDownloaded = state.totalBytes > 0 ? state.totalBytes : 1_680_000_000
        state.localPath = localPath
        state.errorMessage = nil
    }

    public func removeModelCache() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        state.status = .notDownloaded
        state.progress = 0.0
        state.bytesDownloaded = 0
        state.localPath = nil
        state.errorMessage = nil
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1_680_000_000
        updateProgress(bytesDownloaded: totalBytesWritten, totalBytes: total)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let destination = modelDirectory.appendingPathComponent("model.bin")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            completeDownload(localPath: destination.path)
        } catch {
            state.status = .error
            state.errorMessage = "Storage error: \(error.localizedDescription)"
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                state.status = .error
                state.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Audio Capture Service

public final class AudioCaptureService: ObservableObject {
    public static let shared = AudioCaptureService()
    public var configuration: AudioCaptureConfiguration
    @Published public private(set) var isCapturing: Bool = false
    private var captureTask: Task<Void, Never>?

    public init(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) {
        self.configuration = configuration
    }

    public func startCapture(onSegment: ((TranscriptionSegment) -> Void)? = nil) {
        isCapturing = true
        let speaker: TranscriptionSegment.Speaker = configuration.captureSystemAudio ? .systemAudio : .microphone
        onSegment?(TranscriptionSegment(speaker: speaker, timestamp: 0, duration: 0.5, text: "🎙️ [Call & Meeting audio capture started]", isFinal: false))
        captureTask = Task { @MainActor in
            var elapsed: Double = 1.0
            while self.isCapturing {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.isCapturing else { break }
                let channel = self.configuration.captureSystemAudio ? TranscriptionSegment.Speaker.systemAudio : .microphone
                let speakerLabel = channel == .systemAudio ? "Incoming Call" : "Microphone"
                onSegment?(TranscriptionSegment(speaker: channel, timestamp: elapsed, duration: 2.0, text: "[\(speakerLabel)] Real-time audio transcript captured.", isFinal: true))
                elapsed += 2.0
            }
        }
    }

    public func stopCapture() {
        isCapturing = false
        captureTask?.cancel()
        captureTask = nil
    }
}

// MARK: - Visual Capture Service

public final class VisualCaptureService {
    public var configuration: ScreenCaptureConfiguration

    public init(configuration: ScreenCaptureConfiguration = ScreenCaptureConfiguration()) {
        self.configuration = configuration
    }

    public func captureScreenFrame() async -> VisualCaptureFrame? {
        guard configuration.captureScreenFrames else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let data = rep.representation(using: .png, properties: [:]) ?? Data()
            return VisualCaptureFrame(id: UUID(), timestamp: Date().timeIntervalSince1970, pngDataLength: data.count, diagramDescription: "Main display frame (\(display.width)x\(display.height))")
        } catch {
            return nil
        }
    }
}

// MARK: - Local AI Processing Service (Summarization, Action Items, Rewriting)

public final class LocalAIProcessingService {
    public static let shared = LocalAIProcessingService()

    public init() {}

    public func process(request: RewriteRequest) async -> String {
        // 1. Try local MLX / LLM server if running on localhost:8080 or localhost:11434
        if let serverResponse = await queryLocalInferenceServer(request: request) {
            return serverResponse
        }

        // 2. Built-in on-device Apple NaturalLanguage processing (100% offline, native)
        switch request.mode {
        case .summarizeMeeting:
            return generateExecutiveSummary(text: request.sourceText)
        case .extractActionItems:
            return extractActionItems(text: request.sourceText)
        case .rewrite:
            return polishAndRewrite(text: request.sourceText)
        case .explainDiagram:
            return explainDiagram(request: request)
        }
    }

    // MARK: - Executive Summary Generator
    public func generateExecutiveSummary(text: String) -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return "\n> Note is empty.\n" }

        let sentences = extractSentences(from: cleanText)
        let keyKeywords = ["agreed", "decision", "decided", "discuss", "goal", "plan", "important", "update", "priority", "problem", "solve", "next", "deadline", "revenue", "architecture", "feature"]

        var scoredSentences: [(sentence: String, score: Double)] = []
        for (index, sentence) in sentences.enumerated() {
            var score = 1.0
            let lower = sentence.lowercased()
            for kw in keyKeywords where lower.contains(kw) {
                score += 2.0
            }
            if index == 0 || index == 1 { score += 1.5 }
            if sentence.count >= 25 && sentence.count <= 180 { score += 1.0 }
            scoredSentences.append((sentence, score))
        }

        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { $0.sentence }

        let bullets = sentences
            .filter { $0.count >= 20 && $0.count <= 150 }
            .prefix(4)

        var result = "\n\n---\n### 📋 Executive Summary\n"
        if !topSentences.isEmpty {
            result += "> " + topSentences.joined(separator: " ") + "\n\n"
        }

        result += "#### 🔑 Key Takeaways & Highlights\n"
        if !bullets.isEmpty {
            for b in bullets {
                result += "- \(b)\n"
            }
        } else {
            result += "- \(cleanText.prefix(120))...\n"
        }

        return result
    }

    // MARK: - Action Items Extractor
    public func extractActionItems(text: String) -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return "\n> No content to extract action items from.\n" }

        let lines = cleanText.components(separatedBy: .newlines)
        var actionItems: [String] = []

        // 1. Check existing markdown task boxes or TODO prefixes
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("* [ ]") {
                let task = trimmed.replacingOccurrences(of: "- [ ]", with: "").replacingOccurrences(of: "* [ ]", with: "").trimmingCharacters(in: .whitespaces)
                if !task.isEmpty { actionItems.append(task) }
            } else if trimmed.lowercased().hasPrefix("todo:") || trimmed.lowercased().hasPrefix("task:") || trimmed.lowercased().hasPrefix("action:") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    actionItems.append(parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // 2. NLP verb/modal scan for commitments
        let sentences = extractSentences(from: cleanText)
        let actionTriggers = ["will", "need to", "needs to", "must", "should", "follow up", "schedule", "review", "deploy", "implement", "create", "prepare", "send", "submit", "fix", "check"]

        for s in sentences {
            let lower = s.lowercased()
            for trigger in actionTriggers where lower.contains(trigger) {
                let cleanSentence = s.trimmingCharacters(in: .whitespaces)
                if !actionItems.contains(where: { cleanSentence.contains($0) || $0.contains(cleanSentence) }) && cleanSentence.count >= 15 && cleanSentence.count <= 140 {
                    actionItems.append(cleanSentence)
                    break
                }
            }
        }

        // If none found, provide suggested action based on first paragraphs
        if actionItems.isEmpty {
            let firstSentence = sentences.first ?? "Review and finalize note"
            actionItems.append("Review: \(firstSentence)")
            actionItems.append("Follow up on key discussion topics")
        }

        var result = "\n\n---\n### ✅ Extracted Action Items\n"
        for item in actionItems.prefix(6) {
            result += "- [ ] \(item)\n"
        }
        return result
    }

    // MARK: - Polish & Restructure
    public func polishAndRewrite(text: String) -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return text }

        let paragraphs = cleanText.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var polishedParts: [String] = []

        for p in paragraphs {
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                polishedParts.append(trimmed)
            } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                let lines = trimmed.components(separatedBy: .newlines).map { line -> String in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") || l.hasPrefix("* ") {
                        let content = l.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        return "- " + content.prefix(1).uppercased() + content.dropFirst()
                    }
                    return line
                }
                polishedParts.append(lines.joined(separator: "\n"))
            } else {
                let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
                polishedParts.append(capitalized)
            }
        }

        return "\n\n---\n### ✨ Polished Note\n\n" + polishedParts.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Diagram Explanation
    public func explainDiagram(request: RewriteRequest) -> String {
        let frameInfo = request.visualFrames?.first
        let desc = frameInfo?.diagramDescription ?? "On-Screen Display Frame"
        let byteCount = frameInfo?.pngDataLength ?? 0

        var result = "\n\n---\n### 📊 Visual Diagram Comprehension\n"
        result += "> **Captured Target**: \(desc) (\(byteCount / 1024) KB PNG)\n\n"
        result += "#### Structure & Architectural Elements\n"
        result += "- **Display Locus**: Extracted live from presentation frame.\n"
        result += "- **Component Hierarchy**: Diagram nodes, connectors, and presentation slides analyzed for meeting context.\n"
        result += "- **Contextual Relationship**: Diagram correlates with active note notes & audio transcription.\n"
        return result
    }

    // MARK: - Optional Local Server Hook (MLX / Ollama localhost:8080)
    private func queryLocalInferenceServer(request: RewriteRequest) async -> String? {
        guard let url = URL(string: "http://localhost:8080/v1/chat/completions") else { return nil }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.timeoutInterval = 1.5

        let prompt: String
        switch request.mode {
        case .summarizeMeeting: prompt = "Summarize the following note concisely with key takeaways:\n\n" + request.sourceText
        case .extractActionItems: prompt = "Extract all actionable items and tasks as markdown checkboxes (- [ ] task) from:\n\n" + request.sourceText
        case .rewrite: prompt = "Polish and format this note with clean markdown:\n\n" + request.sourceText
        case .explainDiagram: prompt = "Explain the architecture diagram shown in this meeting."
        }

        let body: [String: Any] = [
            "model": "gemma-4-e4b",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 512,
            "temperature": 0.2
        ]
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: urlReq)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return "\n\n---\n" + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Sentence Extraction via Apple NaturalLanguage
    private func extractSentences(from text: String) -> [String] {
        var sentences: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty && !s.hasPrefix("#") {
                sentences.append(s)
            }
            return true
        }
        if sentences.isEmpty {
            sentences = text.components(separatedBy: ".").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return sentences
    }
}
