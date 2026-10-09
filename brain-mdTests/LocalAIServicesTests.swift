//
//  LocalAIServicesTests.swift
//  brain-mdTests
//

import XCTest
@testable import brain_md

final class LocalAIServicesTests: XCTestCase {

    // MARK: - ModelDownloadState & LocalModelManager
    func testModelDownloadStateAndTransitions() {
        let initialState = ModelDownloadState(
            status: .notDownloaded, progress: 0.0, bytesDownloaded: 0, totalBytes: 2_000_000_000,
            modelIdentifier: "gemma-4-e4b"
        )
        XCTAssertEqual(initialState.status, .notDownloaded)
        XCTAssertEqual(initialState.progress, 0.0)

        // Isolated folder: the default location holds the real downloaded model.
        let manager = LocalModelManager(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(manager.state.status, .notDownloaded)

        manager.updateProgress(bytesDownloaded: 1_000_000_000, totalBytes: 2_000_000_000)
        XCTAssertEqual(manager.state.status, .downloading)
        XCTAssertEqual(manager.state.progress, 0.5, accuracy: 0.001)

        manager.completeDownload(localPath: "/tmp/models/gemma-4-e4b.bin")
        XCTAssertEqual(manager.state.status, .ready)
        XCTAssertEqual(manager.state.localPath, "/tmp/models/gemma-4-e4b.bin")

        manager.removeModelCache()
        XCTAssertEqual(manager.state.status, .notDownloaded)
        XCTAssertNil(manager.state.localPath)

        let errorState = ModelDownloadState(
            status: .error, progress: 0.1, bytesDownloaded: 100, totalBytes: 1000,
            modelIdentifier: "gemma-4-e4b", errorMessage: "MODEL_DOWNLOAD_INTERRUPTED"
        )
        XCTAssertEqual(errorState.status, .error)
        XCTAssertEqual(errorState.errorMessage, "MODEL_DOWNLOAD_INTERRUPTED")
    }

    // MARK: - AudioCaptureConfiguration & AudioCaptureService
    func testAudioCaptureConfigurationAndService() {
        let config = AudioCaptureConfiguration(
            captureSystemAudio: true, captureMicrophone: false, sampleRate: 16000.0, channels: 1
        )
        XCTAssertTrue(config.captureSystemAudio)
        XCTAssertFalse(config.captureMicrophone)
        XCTAssertEqual(config.sampleRate, 16000.0)
        XCTAssertEqual(config.channels, 1)

        let service = AudioCaptureService(configuration: config)
        XCTAssertTrue(service.configuration.captureSystemAudio)
        XCTAssertFalse(service.configuration.captureMicrophone)
        XCTAssertEqual(service.configuration.sampleRate, 16000.0)
    }

    // MARK: - ScreenCaptureConfiguration & VisualCaptureService
    func testScreenCaptureConfigurationAndService() {
        let config = ScreenCaptureConfiguration(
            captureScreenFrames: true, frameRate: 2, captureWindowTitles: true
        )
        XCTAssertTrue(config.captureScreenFrames)
        XCTAssertEqual(config.frameRate, 2)
        XCTAssertTrue(config.captureWindowTitles)

        let service = VisualCaptureService(configuration: config)
        XCTAssertTrue(service.configuration.captureScreenFrames)
        XCTAssertEqual(service.configuration.frameRate, 2)
    }

    // MARK: - TranscriptionSegment
    func testTranscriptionSegmentSpeakerDifferentiation() {
        let systemSegment = TranscriptionSegment(
            id: UUID(), speaker: .systemAudio, timestamp: 12.5, duration: 3.0,
            text: "System meeting audio", isFinal: true
        )
        let micSegment = TranscriptionSegment(
            id: UUID(), speaker: .microphone, timestamp: 15.5, duration: 2.0,
            text: "My comment", isFinal: false
        )
        let unknownSegment = TranscriptionSegment(
            id: UUID(), speaker: .unknown, timestamp: 18.0, duration: 1.0,
            text: "Background noise", isFinal: true
        )

        XCTAssertEqual(systemSegment.speaker, .systemAudio)
        XCTAssertEqual(micSegment.speaker, .microphone)
        XCTAssertEqual(unknownSegment.speaker, .unknown)
        XCTAssertTrue(systemSegment.isFinal)
        XCTAssertFalse(micSegment.isFinal)
    }

    // MARK: - VisualCaptureFrame
    func testVisualCaptureFrameMetadata() {
        let frameId = UUID()
        let frame = VisualCaptureFrame(
            id: frameId, timestamp: 42.0, pngDataLength: 1024, diagramDescription: "Architecture flowchart"
        )
        XCTAssertEqual(frame.id, frameId)
        XCTAssertEqual(frame.timestamp, 42.0)
        XCTAssertEqual(frame.pngDataLength, 1024)
        XCTAssertEqual(frame.diagramDescription, "Architecture flowchart")
    }

    // MARK: - RewriteRequest Modes
    func testRewriteRequestModes() {
        let modes: [RewriteRequest.Mode] = [.rewrite, .summarizeMeeting, .extractActionItems, .explainDiagram]
        for mode in modes {
            let request = RewriteRequest(
                mode: mode, sourceText: "Initial draft",
                transcripts: [], visualFrames: []
            )
            XCTAssertEqual(request.mode, mode)
            XCTAssertEqual(request.sourceText, "Initial draft")
        }
    }
}
