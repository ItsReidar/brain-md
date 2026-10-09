//
//  VisualCaptureServiceTests.swift
//  brain-mdTests
//

import CoreGraphics
import Foundation
import ScreenCaptureKit
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

    @Test func disabledPickerCaptureFailsBeforeShowingThePicker() async {
        let service = VisualCaptureService(configuration: ScreenCaptureConfiguration(captureScreenFrames: false))
        await #expect(throws: ScreenCaptureError.disabled) {
            _ = try await service.captureChosenContent()
        }
    }

    @Test func pickerOffersOneWindowAppOrDisplayButNotBrainMD() {
        let configuration = ContentPicker.configuration(excludingBundleID: "be.example.brain-md")
        #expect(configuration.allowedPickerModes == [.singleWindow, .singleApplication, .singleDisplay])
        #expect(configuration.excludedBundleIDs == ["be.example.brain-md"])
        #expect(!configuration.allowsChangingSelectedContent)
        #expect(ContentPicker.configuration(excludingBundleID: nil).excludedBundleIDs.isEmpty)
    }

    @Test func captureSizeIsFullResolution() {
        let retina = VisualCaptureService.pixelSize(of: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(retina.width == 3024)
        #expect(retina.height == 1964)
        let window = VisualCaptureService.pixelSize(of: CGRect(x: 40, y: 60, width: 800.5, height: 600.25), scale: 2)
        #expect(window.width == 1601)
        #expect(window.height == 1201) // 1200.5 rounds up
        let empty = VisualCaptureService.pixelSize(of: .zero, scale: 2)
        #expect(empty.width == 1)
        #expect(empty.height == 1)
    }
}
