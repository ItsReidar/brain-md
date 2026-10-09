//
//  LocalAIModels.swift
//  brain-md
//

import Foundation

public struct ModelDownloadState: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case notDownloaded, downloading, ready, error
    }
    public var status: Status
    public var progress: Double
    public var bytesDownloaded: Int64, totalBytes: Int64
    public var modelIdentifier: String
    public var localPath: String?, errorMessage: String?

    public init(status: Status = .notDownloaded, progress: Double = 0.0, bytesDownloaded: Int64 = 0, totalBytes: Int64 = 0, modelIdentifier: String = "", localPath: String? = nil, errorMessage: String? = nil) {
        self.status = status; self.progress = progress; self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes; self.modelIdentifier = modelIdentifier
        self.localPath = localPath; self.errorMessage = errorMessage
    }
}

public struct AudioCaptureConfiguration: Equatable, Sendable {
    public var captureSystemAudio: Bool, captureMicrophone: Bool
    public var sampleRate: Double
    public var channels: Int

    public init(captureSystemAudio: Bool = false, captureMicrophone: Bool = false, sampleRate: Double = 16000.0, channels: Int = 1) {
        self.captureSystemAudio = captureSystemAudio; self.captureMicrophone = captureMicrophone
        self.sampleRate = sampleRate; self.channels = channels
    }
}

public struct ScreenCaptureConfiguration: Equatable, Sendable {
    public var captureScreenFrames: Bool, captureWindowTitles: Bool
    public var frameRate: Int

    public init(captureScreenFrames: Bool = false, frameRate: Int = 1, captureWindowTitles: Bool = true) {
        self.captureScreenFrames = captureScreenFrames; self.frameRate = frameRate
        self.captureWindowTitles = captureWindowTitles
    }
}

public struct TranscriptionSegment: Identifiable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable {
        case systemAudio, microphone, unknown
    }
    public var id: UUID
    public var speaker: Speaker
    public var timestamp: Double, duration: Double
    public var text: String
    public var isFinal: Bool

    public init(id: UUID = UUID(), speaker: Speaker = .unknown, timestamp: Double = 0.0, duration: Double = 0.0, text: String = "", isFinal: Bool = false) {
        self.id = id; self.speaker = speaker; self.timestamp = timestamp
        self.duration = duration; self.text = text; self.isFinal = isFinal
    }
}

public struct VisualCaptureFrame: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Double
    public var pngDataLength: Int
    public var diagramDescription: String?

    public init(id: UUID = UUID(), timestamp: Double = 0.0, pngDataLength: Int = 0, diagramDescription: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.pngDataLength = pngDataLength
        self.diagramDescription = diagramDescription
    }
}

public struct RewriteRequest: Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case rewrite, summarizeMeeting, extractActionItems, explainDiagram
    }
    public var mode: Mode
    public var sourceText: String
    public var transcripts: [TranscriptionSegment]?
    public var visualFrames: [VisualCaptureFrame]?

    public init(mode: Mode = .rewrite, sourceText: String = "", transcripts: [TranscriptionSegment]? = nil, visualFrames: [VisualCaptureFrame]? = nil) {
        self.mode = mode; self.sourceText = sourceText
        self.transcripts = transcripts; self.visualFrames = visualFrames
    }
}
