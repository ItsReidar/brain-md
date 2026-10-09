//
//  VisualCaptureServiceTests.swift
//  brain-mdTests
//

import CoreGraphics
import Foundation
import Testing
@testable import brain_md

@MainActor
struct VisualCaptureServiceTests {

    @Test func cocoaPointsMapToTopLeftOrigin() {
        // Pointer near the top of a 1117-pt-high primary display.
        #expect(VisualCaptureService.quartzPoint(fromCocoa: CGPoint(x: 100, y: 1100), primaryScreenHeight: 1117)
            == CGPoint(x: 100, y: 17))
        // Pointer on a second display placed above the primary one (negative Quartz y).
        #expect(VisualCaptureService.quartzPoint(fromCocoa: CGPoint(x: 400, y: 1500), primaryScreenHeight: 1117)
            == CGPoint(x: 400, y: -383))
    }

    @Test func disabledCaptureFailsBeforeAskingForPermission() async {
        let service = VisualCaptureService(configuration: ScreenCaptureConfiguration(captureScreenFrames: false))
        await #expect(throws: ScreenCaptureError.disabled) {
            _ = try await service.captureScreen()
        }
    }
}
