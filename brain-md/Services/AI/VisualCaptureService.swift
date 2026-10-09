//
//  VisualCaptureService.swift
//  brain-md
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenCaptureError: LocalizedError, Equatable {
    case disabled
    case permissionDenied
    case noDisplay

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Screen explanations are turned off in Settings › Local AI & Voice."
        case .permissionDenied:
            "brain-md needs Screen Recording permission. Allow it in System Settings › Privacy & Security › "
                + "Screen & System Audio Recording, then try again."
        case .noDisplay:
            "No display was found to capture."
        }
    }
}

/// Captures what's on screen so Gemma can explain slides and diagrams.
public final class VisualCaptureService {
    public var configuration: ScreenCaptureConfiguration

    public init(configuration: ScreenCaptureConfiguration = ScreenCaptureConfiguration()) {
        self.configuration = configuration
    }

    /// Captures the display under the mouse pointer at full resolution, leaving out brain-md's own
    /// windows so a slide behind the note is what gets captured.
    public func captureScreen() async throws -> CGImage {
        guard configuration.captureScreenFrames else { throw ScreenCaptureError.disabled }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.permissionDenied
        }

        let pointer = Self.quartzPoint(
            fromCocoa: NSEvent.mouseLocation, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
        guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first
        else { throw ScreenCaptureError.noDisplay }

        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        streamConfiguration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        streamConfiguration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw ScreenCaptureError.permissionDenied
        }
    }

    /// Converts AppKit's bottom-left-origin screen point to the top-left-origin space ScreenCaptureKit uses.
    static func quartzPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}
