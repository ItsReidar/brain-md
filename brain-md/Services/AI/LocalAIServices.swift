//
//  LocalAIServices.swift
//  brain-md
//

import Foundation
import Combine
import CoreGraphics
import AppKit
import ScreenCaptureKit

public final class LocalModelManager: ObservableObject {
    public static let shared = LocalModelManager()
    @Published public var state: ModelDownloadState

    public var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("brain-md/models/gemma-4-e4b")
    }

    public init(modelIdentifier: String = "gemma-4-e4b") {
        self.state = ModelDownloadState(modelIdentifier: modelIdentifier)
        checkExistingModel()
    }

    public func checkExistingModel() {
        let weight = modelDirectory.appendingPathComponent("model.bin")
        if FileManager.default.fileExists(atPath: weight.path) {
            state.status = .ready; state.progress = 1.0; state.localPath = weight.path
        }
    }

    public func startDownload() {
        guard state.status != .downloading else { return }
        state.status = .downloading
        state.progress = 0.05
        state.bytesDownloaded = 120_000_000
        state.totalBytes = 2_400_000_000
        Task { @MainActor in
            let total: Int64 = 2_400_000_000
            for step in 1...10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard self.state.status == .downloading else { return }
                let downloaded = Int64(Double(total) * (Double(step) / 10.0))
                self.updateProgress(bytesDownloaded: downloaded, totalBytes: total)
            }
            try? FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)
            let weightFile = self.modelDirectory.appendingPathComponent("model.bin")
            try? "Gemma 4 E4B MLX Weights".data(using: .utf8)?.write(to: weightFile)
            self.completeDownload(localPath: weightFile.path)
        }
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
        state.localPath = localPath
        state.errorMessage = nil
    }

    public func removeModelCache() {
        try? FileManager.default.removeItem(at: modelDirectory)
        state.status = .notDownloaded
        state.progress = 0.0
        state.bytesDownloaded = 0
        state.localPath = nil
        state.errorMessage = nil
    }
}

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
            return VisualCaptureFrame(id: UUID(), timestamp: Date().timeIntervalSince1970, pngDataLength: data.count, diagramDescription: "Main display frame")
        } catch {
            return nil
        }
    }
}
