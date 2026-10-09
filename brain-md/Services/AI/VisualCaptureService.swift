//
//  VisualCaptureService.swift
//  brain-md
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

public enum ScreenCaptureError: LocalizedError, Equatable {
    case disabled
    case permissionDenied
    case noDisplay
    case pickerUnavailable

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Screen explanations are turned off in Settings › Local AI & Voice."
        case .permissionDenied:
            "brain-md needs Screen Recording permission. Allow it in System Settings › Privacy & Security › "
                + "Screen & System Audio Recording, then try again."
        case .noDisplay:
            "No display was found to capture."
        case .pickerUnavailable:
            "The window picker couldn't open. Try Screen Under Pointer instead."
        }
    }
}

/// A captured image and a short name for what it shows ("Safari", "Built-in Display").
public struct ScreenCapture {
    public let image: CGImage
    public let label: String
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
        return try await capture(SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: []))
    }

    /// Shows the system picker and captures what the user chooses: a window, an app or a display.
    /// Returns nil when the picker is cancelled. Picker captures don't need Screen Recording permission.
    public func captureChosenContent() async throws -> ScreenCapture? {
        guard configuration.captureScreenFrames else { throw ScreenCaptureError.disabled }
        guard let picked = try await ContentPicker.shared.pick() else { return nil }
        let filter = await Self.excludingOwnWindows(picked)
        return ScreenCapture(image: try await capture(filter), label: Self.label(for: picked))
    }

    private func capture(_ filter: SCContentFilter) async throws -> CGImage {
        let size = Self.pixelSize(of: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = size.width
        streamConfiguration.height = size.height
        streamConfiguration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw ScreenCaptureError.permissionDenied
        }
    }

    /// A picked display would otherwise include brain-md's own window in front of the slide. Leaving
    /// it out needs the shareable-content list, so it's only done when permission was already
    /// granted; checking doesn't prompt.
    private static func excludingOwnWindows(_ filter: SCContentFilter) async -> SCContentFilter {
        guard filter.style == .display, let display = filter.includedDisplays.first, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return filter }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
    }

    private static func label(for filter: SCContentFilter) -> String {
        switch filter.style {
        case .window:
            if let window = filter.includedWindows.first {
                let app = window.owningApplication?.applicationName ?? ""
                let title = window.title ?? ""
                return [app, title].filter { !$0.isEmpty }.joined(separator: " – ").nilIfEmpty ?? "Window"
            }
            return "Window"
        case .application:
            return filter.includedApplications.first?.applicationName.nilIfEmpty ?? "App"
        case .display:
            guard let display = filter.includedDisplays.first else { return "Display" }
            return NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == display.displayID
            }?.localizedName ?? "Display"
        default:
            return "Screen"
        }
    }

    /// Full-resolution pixel size of a capture: points × backing scale, at least 1×1.
    static func pixelSize(of contentRect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((contentRect.width * scale).rounded())), max(1, Int((contentRect.height * scale).rounded())))
    }

    /// Converts AppKit's bottom-left-origin screen point to the top-left-origin space ScreenCaptureKit uses.
    static func quartzPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

/// Wraps the system content-sharing picker (the one used when sharing a screen in a call) in one
/// async call. Only one pick runs at a time; starting another cancels the first.
final class ContentPicker: NSObject, SCContentSharingPickerObserver {
    static let shared = ContentPicker()

    private let pending = OSAllocatedUnfairLock<CheckedContinuation<SCContentFilter?, Error>?>(initialState: nil)

    func pick() async throws -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = Self.configuration(excludingBundleID: Bundle.main.bundleIdentifier)
        picker.add(self)
        picker.isActive = true
        defer {
            picker.remove(self)
            picker.isActive = false
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { previous in
                previous?.resume(returning: nil)
                previous = continuation
            }
            picker.present()
        }
    }

    /// One window, one app or one display; brain-md itself isn't offered.
    static func configuration(excludingBundleID bundleID: String?) -> SCContentSharingPickerConfiguration {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
        configuration.excludedBundleIDs = bundleID.map { [$0] } ?? []
        configuration.allowsChangingSelectedContent = false
        return configuration
    }

    private nonisolated func finish(_ result: Result<SCContentFilter?, Error>) {
        pending.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finish(.success(filter))
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.success(nil))
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(ScreenCaptureError.pickerUnavailable))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
