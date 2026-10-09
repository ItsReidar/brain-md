//
//  AudioCaptureService.swift
//  brain-md
//

import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

public enum AudioCaptureError: LocalizedError, Equatable {
    case nothingToCapture
    case microphoneDenied
    case screenRecordingDenied
    case noDisplay

    public var errorDescription: String? {
        switch self {
        case .nothingToCapture:
            "Both system audio and microphone capture are turned off in Settings › Local AI & Voice."
        case .microphoneDenied:
            "brain-md needs microphone access. Allow it in System Settings › Privacy & Security › Microphone."
        case .screenRecordingDenied:
            "Capturing meeting audio needs Screen & System Audio Recording permission. Allow brain-md in "
                + "System Settings › Privacy & Security, then try again."
        case .noDisplay:
            "No display was found to attach the audio capture to."
        }
    }
}

/// One chunk of captured audio, labelled with where it came from.
nonisolated public struct CapturedAudio: @unchecked Sendable {
    public let speaker: TranscriptionSegment.Speaker
    public let buffer: AVAudioPCMBuffer
    public let time: CMTime
}

/// Captures system audio (other meeting participants) and the microphone (you) through one
/// ScreenCaptureKit stream, so both sources share a clock. Audio never leaves the Mac.
public final class AudioCaptureService: NSObject, ObservableObject {
    public static let shared = AudioCaptureService()

    public var configuration: AudioCaptureConfiguration
    @Published public private(set) var isCapturing = false
    /// Loudness per source in 0…1 (−60 dBFS…0 dBFS), for a live level meter.
    @Published public private(set) var systemLevel: Float = 0
    @Published public private(set) var microphoneLevel: Float = 0
    @Published public private(set) var lastError: String?

    private var stream: SCStream?
    /// Written on the main actor, read on the capture queue: delivers buffers in order without a main-thread hop.
    private nonisolated let continuation = OSAllocatedUnfairLock<AsyncStream<CapturedAudio>.Continuation?>(initialState: nil)
    private let sampleQueue = DispatchQueue(label: "brain-md.audio-capture", qos: .userInitiated)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "AudioCapture")

    public init(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) {
        self.configuration = configuration
    }

    /// Starts capturing and returns the audio as it arrives. The stream finishes on `stop()` or on error.
    public func start() async throws -> AsyncStream<CapturedAudio> {
        await stop()
        let wantsSystem = configuration.captureSystemAudio
        let wantsMicrophone = configuration.captureMicrophone
        guard wantsSystem || wantsMicrophone else { throw AudioCaptureError.nothingToCapture }

        if wantsMicrophone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            throw AudioCaptureError.microphoneDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AudioCaptureError.screenRecordingDenied
        }
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.capturesAudio = wantsSystem
        streamConfiguration.captureMicrophone = wantsMicrophone
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = Int(configuration.sampleRate)
        streamConfiguration.channelCount = configuration.channels
        // Audio-only: keep the mandatory video track as small and infrequent as possible.
        streamConfiguration.width = 2
        streamConfiguration.height = 2
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantsSystem { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue) }
        if wantsMicrophone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue) }

        let (audio, continuation) = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation.withLock { $0 = continuation }
        do {
            try await stream.startCapture()
        } catch {
            finish()
            if (error as? SCStreamError)?.code == .userDeclined { throw AudioCaptureError.screenRecordingDenied }
            throw error
        }
        self.stream = stream
        isCapturing = true
        lastError = nil
        log.info("Audio capture started (system: \(wantsSystem), microphone: \(wantsMicrophone))")
        return audio
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        finish()
    }

    private func finish() {
        continuation.withLock { continuation in
            continuation?.finish()
            continuation = nil
        }
        isCapturing = false
        systemLevel = 0
        microphoneLevel = 0
    }

    // MARK: - Helpers

    /// Copies a ScreenCaptureKit audio sample buffer into an `AVAudioPCMBuffer`.
    nonisolated static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }
        var asbd = streamDescription.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Loudness of the first channel mapped to 0…1 (−60 dBFS → 0, 0 dBFS → 1). Non-float buffers report 0.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension AudioCaptureService: SCStreamOutput, SCStreamDelegate {
    public nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let speaker: TranscriptionSegment.Speaker
        switch type {
        case .audio: speaker = .systemAudio
        case .microphone: speaker = .microphone
        default: return // ignore the placeholder video frames
        }
        guard sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let captured = CapturedAudio(speaker: speaker, buffer: buffer, time: sampleBuffer.presentationTimeStamp)
        continuation.withLock { _ = $0?.yield(captured) }
        let level = Self.level(of: buffer)
        Task { @MainActor in
            if speaker == .systemAudio { self.systemLevel = level } else { self.microphoneLevel = level }
        }
    }

    public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.log.error("Audio capture stopped: \(error.localizedDescription, privacy: .public)")
            self.lastError = error.localizedDescription
            self.stream = nil
            self.finish()
        }
    }
}
