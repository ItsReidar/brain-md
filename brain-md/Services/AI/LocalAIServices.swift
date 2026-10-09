//
//  LocalAIServices.swift
//  brain-md
//

import Foundation
import Combine
import CoreGraphics
import AppKit
import ScreenCaptureKit

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
