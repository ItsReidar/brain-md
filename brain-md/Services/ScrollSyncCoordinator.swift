//
//  ScrollSyncCoordinator.swift
//  brain-md
//

import SwiftUI
import AppKit
import Combine
import os

/// Identifies which pane initiated the current scroll action.
public enum ScrollSource {
    case editor
    case preview
}

/// Coordinates bidirectional proportional scroll synchronization between
/// the native AppKit Markdown editor and the rendered preview in Split View.
///
/// Anti-feedback strategy:
///
/// 1. **Synchronous lock** (`isSyncingScroll`): set while the coordinator scrolls the
///    follower, so the `boundsDidChangeNotification` that fires synchronously inside
///    `contentView.scroll(to:)` never drives a reciprocal sync.
///
/// 2. **Live-scroll driver** (`activeDriver`): the pane that posted
///    `willStartLiveScrollNotification` (trackpad gesture, momentum, scroller drag) owns
///    the sync until `didEndLiveScrollNotification`. Bounds changes on the other pane are
///    ignored meanwhile, so follower momentum or layout never fights AppKit bounce physics.
///
/// 3. **User intent**: without a live driver, a bounds change only drives the peer when the
///    current event is a wheel/mouse event over that pane or a key press while it holds
///    focus. Layout-driven bounds changes (preview re-render, SwiftUI re-layout) are ignored.
///
/// Mapping is proportional and idempotent, so a deferred echo always round-trips to the same
/// position and falls under `minimumScrollDelta`, which terminates any remaining ping-pong.
@MainActor
public final class ScrollSyncCoordinator: ObservableObject {
    public static let shared = ScrollSyncCoordinator()

    @Published public var isSyncEnabled: Bool = true

    public private(set) weak var editorScrollView: NSScrollView?
    public private(set) weak var previewScrollView: NSScrollView?

    /// The pane currently being scrolled by a live user gesture, if any.
    public private(set) var activeDriver: ScrollSource?

    /// Synchronous re-entrancy lock held while the coordinator scrolls the follower pane.
    private var isSyncingScroll = false

    private var editorObservers: [NSObjectProtocol] = []
    private var previewObservers: [NSObjectProtocol] = []

    /// Smallest offset change worth applying (one Retina pixel). Prevents micro-jitter and
    /// guarantees echo round-trips terminate.
    static let minimumScrollDelta: CGFloat = 0.5

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "ScrollSync")

    public init() {}

    isolated deinit {
        (editorObservers + previewObservers).forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Registration

    public func registerEditor(_ scrollView: NSScrollView) {
        if editorScrollView === scrollView && !editorObservers.isEmpty { return }
        unregisterEditor()
        editorScrollView = scrollView
        editorObservers = observe(scrollView, as: .editor)
        Self.log.debug("registered editor scroll view")
    }

    public func registerPreview(_ scrollView: NSScrollView) {
        if previewScrollView === scrollView && !previewObservers.isEmpty { return }
        unregisterPreview()
        previewScrollView = scrollView
        previewObservers = observe(scrollView, as: .preview)
        Self.log.debug("registered preview scroll view")
    }

    public func unregisterEditor() {
        editorObservers.forEach { NotificationCenter.default.removeObserver($0) }
        editorObservers = []
        editorScrollView = nil
        if activeDriver == .editor { activeDriver = nil }
    }

    public func unregisterPreview() {
        previewObservers.forEach { NotificationCenter.default.removeObserver($0) }
        previewObservers = []
        previewScrollView = nil
        if activeDriver == .preview { activeDriver = nil }
    }

    /// Unregisters the editor only if `scrollView` is the one currently registered.
    /// SwiftUI may build a replacement view before dismantling the old one, so an
    /// unconditional unregister would drop the new registration.
    public func unregisterEditor(_ scrollView: NSScrollView) {
        guard editorScrollView === scrollView else { return }
        unregisterEditor()
        Self.log.debug("unregistered editor scroll view")
    }

    /// Unregisters the preview only if `scrollView` is the one currently registered.
    public func unregisterPreview(_ scrollView: NSScrollView) {
        guard previewScrollView === scrollView else { return }
        unregisterPreview()
        Self.log.debug("unregistered preview scroll view")
    }

    private func observe(_ scrollView: NSScrollView, as source: ScrollSource) -> [NSObjectProtocol] {
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        // `queue: nil` delivers synchronously on the posting thread. AppKit posts these on
        // the main thread, which `assumeIsolated` asserts instead of hopping asynchronously.
        return [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipBoundsDidChange(for: source) }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.activeDriver = source }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeDriver == source else { return }
                    self.activeDriver = nil
                }
            }
        ]
    }

    // MARK: - Scroll Handling

    /// Called when the user scrolled the editor; syncs the preview to match.
    public func handleEditorScrolled() {
        sync(from: .editor)
    }

    /// Called when the user scrolled the preview; syncs the editor to match.
    public func handlePreviewScrolled() {
        sync(from: .preview)
    }

    private func clipBoundsDidChange(for source: ScrollSource) {
        guard !isSyncingScroll,
              let scrollView = scrollView(for: source),
              isUserDriven(source, scrollView) else { return }
        sync(from: source)
    }

    private func isUserDriven(_ source: ScrollSource, _ scrollView: NSScrollView) -> Bool {
        if let driver = activeDriver {
            return driver == source
        }
        guard let event = NSApp.currentEvent, event.window === scrollView.window else { return false }
        switch event.type {
        case .scrollWheel, .leftMouseDown, .leftMouseDragged:
            let location = scrollView.convert(event.locationInWindow, from: nil)
            return scrollView.bounds.contains(location)
        case .keyDown:
            return (scrollView.window?.firstResponder as? NSView)?.isDescendant(of: scrollView) == true
        default:
            return false
        }
    }

    private func scrollView(for source: ScrollSource) -> NSScrollView? {
        switch source {
        case .editor: return editorScrollView
        case .preview: return previewScrollView
        }
    }

    private func sync(from source: ScrollSource) {
        guard isSyncEnabled, !isSyncingScroll,
              let editor = editorScrollView,
              let preview = previewScrollView else { return }
        switch source {
        case .editor: syncScroll(from: editor, to: preview)
        case .preview: syncScroll(from: preview, to: editor)
        }
    }

    /// Core proportional sync logic. Maps the source's scroll progress to the equivalent,
    /// strictly clamped position in the target and applies it under the sync lock.
    public func syncScroll(from source: NSScrollView, to target: NSScrollView) {
        guard let sourceMetrics = ScrollMetrics(source),
              let targetMetrics = ScrollMetrics(target) else { return }

        let progress = sourceMetrics.progress
        let targetOffset = targetMetrics.clampedOffset(forProgress: progress)
        guard abs(targetOffset - targetMetrics.offset) >= Self.minimumScrollDelta else { return }

        let origin = NSPoint(x: target.contentView.bounds.origin.x,
                             y: targetMetrics.clipOriginY(forOffset: targetOffset))
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)

        Self.log.debug("""
            sync progress=\(progress, format: .fixed(precision: 3), privacy: .public) \
            source[\(sourceMetrics.debugDescription, privacy: .public)] \
            target[\(targetMetrics.debugDescription, privacy: .public)] \
            targetOffset=\(targetOffset, privacy: .public) clipY=\(target.contentView.bounds.origin.y, privacy: .public)
            """)
    }

    // MARK: - Calculation Helpers

    /// Calculates the true scrollable content height of a document view.
    /// For an `NSTextView`, the frame can be taller than its text (it never shrinks below
    /// `minSize`), so the TextKit layout height is used, capped by the frame AppKit scrolls within.
    public static func effectiveContentHeight(for documentView: NSView) -> CGFloat {
        let frameHeight = documentView.frame.height
        if let textView = documentView as? NSTextView,
           let textContainer = textView.textContainer,
           let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let usedHeight = ceil(usedRect.height + textView.textContainerInset.height * 2)
            if usedHeight > 0 {
                return min(frameHeight, usedHeight)
            }
        }
        return frameHeight
    }

    public static func calculateProgress(offsetY: CGFloat, docHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        progress(offset: offsetY, minOffset: 0, maxOffset: docHeight - visibleHeight)
    }

    public static func calculateTargetOffset(progress: CGFloat, targetDocHeight: CGFloat, targetVisibleHeight: CGFloat) -> CGFloat {
        offset(forProgress: progress, minOffset: 0, maxOffset: max(0, targetDocHeight - targetVisibleHeight))
    }

    /// Normalized position in `[0, 1]`; elastic overscroll on either side clamps to the bound.
    static func progress(offset: CGFloat, minOffset: CGFloat, maxOffset: CGFloat) -> CGFloat {
        let range = maxOffset - minOffset
        guard range > 0 else { return 0 }
        return min(1, max(0, (offset - minOffset) / range))
    }

    /// Offset for `progress`, clamped strictly to `[minOffset, maxOffset]`.
    static func offset(forProgress progress: CGFloat, minOffset: CGFloat, maxOffset: CGFloat) -> CGFloat {
        guard maxOffset > minOffset else { return minOffset }
        let clampedProgress = min(1, max(0, progress))
        let targetY = minOffset + clampedProgress * (maxOffset - minOffset)
        return max(minOffset, min(targetY, maxOffset))
    }
}

// MARK: - Scroll Geometry

/// Scroll geometry of an `NSScrollView`, normalized to "points scrolled from the top of the
/// document" regardless of the document view's frame origin, flippedness or content insets.
struct ScrollMetrics: CustomDebugStringConvertible {
    /// Distance from the top of the document to the top of the visible area.
    let offset: CGFloat
    /// Topmost reachable offset (`-contentInsets.top`; `0` without insets).
    let minOffset: CGFloat
    /// Bottommost offset that still shows content (never past the end of the text).
    let maxOffset: CGFloat

    private let isFlipped: Bool
    private let documentFrame: NSRect
    private let visibleHeight: CGFloat

    init?(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return nil }
        let clipBounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        let contentHeight = ScrollSyncCoordinator.effectiveContentHeight(for: documentView)

        isFlipped = documentView.isFlipped
        // The document frame is expressed in clip-view coordinates; its origin is not
        // guaranteed to be zero, so every offset is measured relative to it.
        documentFrame = documentView.frame
        visibleHeight = clipBounds.height
        offset = isFlipped
            ? clipBounds.minY - documentFrame.minY
            : documentFrame.maxY - clipBounds.maxY
        minOffset = -insets.top
        maxOffset = max(minOffset, contentHeight - visibleHeight + insets.bottom)
    }

    var progress: CGFloat {
        ScrollSyncCoordinator.progress(offset: offset, minOffset: minOffset, maxOffset: maxOffset)
    }

    func clampedOffset(forProgress progress: CGFloat) -> CGFloat {
        ScrollSyncCoordinator.offset(forProgress: progress, minOffset: minOffset, maxOffset: maxOffset)
    }

    /// Clip-view bounds origin Y that places the top of the visible area at `offset`.
    func clipOriginY(forOffset offset: CGFloat) -> CGFloat {
        isFlipped
            ? documentFrame.minY + offset
            : documentFrame.maxY - offset - visibleHeight
    }

    var debugDescription: String {
        let format = { (value: CGFloat) in String(format: "%.1f", value) }
        return "offset=\(format(offset)) min=\(format(minOffset)) max=\(format(maxOffset)) " +
            "docY=\(format(documentFrame.minY)) docH=\(format(documentFrame.height)) " +
            "visibleH=\(format(visibleHeight)) flipped=\(isFlipped)"
    }
}
