//
//  ScrollSyncTests.swift
//  brain-mdTests
//
//

import Testing
import Foundation
import AppKit
import SwiftUI
@testable import brain_md

@Suite(.serialized)
@MainActor
struct ScrollSyncTests {
    
    @Test func testScrollProgressCalculation() {
        // Normal mid-range
        let p1 = ScrollSyncCoordinator.calculateProgress(offsetY: 100, docHeight: 300, visibleHeight: 100)
        #expect(p1 == 0.5)
        
        // At top
        let pTop = ScrollSyncCoordinator.calculateProgress(offsetY: 0, docHeight: 500, visibleHeight: 200)
        #expect(pTop == 0.0)
        
        // At bottom
        let pBottom = ScrollSyncCoordinator.calculateProgress(offsetY: 300, docHeight: 500, visibleHeight: 200)
        #expect(pBottom == 1.0)
        
        // Negative / rubber-band top clamped to 0.0
        let pOverscrollTop = ScrollSyncCoordinator.calculateProgress(offsetY: -50, docHeight: 500, visibleHeight: 200)
        #expect(pOverscrollTop == 0.0)
        
        // Overscroll bottom clamped to 1.0
        let pOverscrollBottom = ScrollSyncCoordinator.calculateProgress(offsetY: 450, docHeight: 500, visibleHeight: 200)
        #expect(pOverscrollBottom == 1.0)
        
        // Document smaller than visible area (cannot scroll)
        let pShort = ScrollSyncCoordinator.calculateProgress(offsetY: 0, docHeight: 100, visibleHeight: 200)
        #expect(pShort == 0.0)
    }
    
    @Test func testTargetOffsetCalculation() {
        // Normal 50% target
        let t1 = ScrollSyncCoordinator.calculateTargetOffset(progress: 0.5, targetDocHeight: 600, targetVisibleHeight: 200)
        #expect(t1 == 200.0)
        
        // 100% target
        let tFull = ScrollSyncCoordinator.calculateTargetOffset(progress: 1.0, targetDocHeight: 800, targetVisibleHeight: 300)
        #expect(tFull == 500.0)
        
        // 0% target
        let tZero = ScrollSyncCoordinator.calculateTargetOffset(progress: 0.0, targetDocHeight: 800, targetVisibleHeight: 300)
        #expect(tZero == 0.0)
        
        // Short target document
        let tShort = ScrollSyncCoordinator.calculateTargetOffset(progress: 0.8, targetDocHeight: 150, targetVisibleHeight: 300)
        #expect(tShort == 0.0)
    }
    
    @Test func testCoordinatorSyncToggleAndRegistration() {
        let coordinator = ScrollSyncCoordinator()
        #expect(coordinator.isSyncEnabled == true)
        
        coordinator.isSyncEnabled = false
        #expect(coordinator.isSyncEnabled == false)
        
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)
        
        #expect(coordinator.editorScrollView === editorSV)
        #expect(coordinator.previewScrollView === previewSV)
        
        coordinator.unregisterEditor()
        #expect(coordinator.editorScrollView == nil)
        
        coordinator.unregisterPreview()
        #expect(coordinator.previewScrollView == nil)
    }
    
    @Test func testReentrantSafeBidirectionalSync() {
        let coordinator = ScrollSyncCoordinator()
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        
        let editorDoc = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        let previewDoc = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        editorSV.documentView = editorDoc
        previewSV.documentView = previewDoc
        
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)
        
        // 1. Preview scrolls to bottom: 3000 - 600 = 2400 (100%)
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: 2400))
        coordinator.handlePreviewScrolled()
        
        // Editor must be scrolled to its exact bottom: 2000 - 600 = 1400 (100%)
        let editorY = editorSV.contentView.bounds.origin.y
        #expect(abs(editorY - 1400.0) < 1.0)
        
        // 2. Editor notification triggers synchronously/asynchronously: should not bounce preview!
        coordinator.handleEditorScrolled()
        #expect(abs(previewSV.contentView.bounds.origin.y - 2400.0) < 1.0)
        
        // 3. User now scrolls preview back up to 1800 (75% progress).
        // Editor must follow smoothly back up to 1050 (75% of 1400)!
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: 1800))
        coordinator.handlePreviewScrolled()
        
        let editorAfterUp = editorSV.contentView.bounds.origin.y
        let expected1800 = 1800.0 * (1400.0 / 2400.0) // 1050.0
        #expect(abs(editorAfterUp - expected1800) < 1.0)
        
        // 4. User scrolls editor to 350 (25% of 1400).
        // Preview must follow smoothly to 600 (25% of 2400)!
        editorSV.contentView.scroll(to: NSPoint(x: 0, y: 350))
        coordinator.handleEditorScrolled()
        #expect(abs(previewSV.contentView.bounds.origin.y - 600.0) < 1.0)
        
        // 5. User scrolls editor all the way back to 0.
        // Preview must follow back to 0!
        editorSV.contentView.scroll(to: NSPoint(x: 0, y: 0))
        coordinator.handleEditorScrolled()
        #expect(abs(previewSV.contentView.bounds.origin.y - 0.0) < 1.0)
    }
    
    @Test func testRegistrationIdempotency() {
        let coordinator = ScrollSyncCoordinator()
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        
        coordinator.registerPreview(previewSV)
        let firstSV = coordinator.previewScrollView
        
        // Re-registering the same scroll view should be a no-op
        coordinator.registerPreview(previewSV)
        #expect(coordinator.previewScrollView === firstSV)
    }
    
    @Test func testBottomOverscrollClamping() {
        // Source is 100pt past the bottom (overscroll rubber-banding)
        let overscrollProgress = ScrollSyncCoordinator.calculateProgress(
            offsetY: 700, // max is 1000 - 400 = 600
            docHeight: 1000,
            visibleHeight: 400
        )
        #expect(overscrollProgress == 1.0)
        
        // Target offset remains strictly at target maxScroll
        let targetOffset = ScrollSyncCoordinator.calculateTargetOffset(
            progress: overscrollProgress,
            targetDocHeight: 800,
            targetVisibleHeight: 400
        )
        #expect(targetOffset == 400.0) // 800 - 400 = 400
    }
    
    @Test func testEffectiveContentHeightForNSTextView() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 25000)) // Artificially bloated frame
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
        
        let effectiveHeight = ScrollSyncCoordinator.effectiveContentHeight(for: textView)
        // Effective height must reflect real text layout (~100-200pt), NOT the 25,000pt frame!
        #expect(effectiveHeight < 1000)
        #expect(effectiveHeight > 50)
        #expect(effectiveHeight != textView.bounds.height)
    }
    
    @Test func testSyncScrollWithBloatedNSTextViewDoesNotScrollIntoVoid() {
        let coordinator = ScrollSyncCoordinator()
        
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 20000))
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = String(repeating: "Line of text\n", count: 80)
        editorSV.documentView = textView
        
        let previewDoc = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        previewSV.documentView = previewDoc
        
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)
        
        // Scroll preview to 100% (the bottom)
        let maxPreviewScroll = 4000.0 - 600.0 // 3400
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: maxPreviewScroll))
        coordinator.handlePreviewScrolled()
        
        // Editor should be scrolled to its effective text height - 600, NOT (20,000 - 600 = 19,400)!
        let editorY = editorSV.contentView.bounds.origin.y
        let effectiveHeight = ScrollSyncCoordinator.effectiveContentHeight(for: textView)
        let expectedMaxY = max(0, effectiveHeight - 600.0)
        #expect(abs(editorY - expectedMaxY) < 1.0)
        #expect(editorY < 3000.0) // Must never reach the void
    }
    
    @Test func testSwiftUIScrollViewFlippedness() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let hostingView = NSHostingView(rootView: ScrollView {
            VStack {
                Text("Top")
                Color.clear.frame(height: 1000)
                Text("Bottom")
            }
        })
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        window.contentView = hostingView
        window.display()
        
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }
        
        let sv = findScrollView(in: hostingView)
        #expect(sv != nil)
        if let sv = sv {
            #expect(sv.documentView?.isFlipped == true)
            #expect(sv.contentView.isFlipped == true)
            let docHeight = sv.documentView?.bounds.height ?? 0
            let visibleHeight = sv.contentView.bounds.height
            // Check if documentView height reflects the 1000+ content height
            #expect(docHeight >= 1000)
            
            // Scroll to bottom
            let maxScroll = docHeight - visibleHeight
            sv.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
            #expect(sv.contentView.bounds.origin.y == maxScroll)
            
            // Scroll back up to 200
            sv.contentView.scroll(to: NSPoint(x: 0, y: 200))
            #expect(sv.contentView.bounds.origin.y == 200)
        }
    }
    
    @Test func testSimulatedScrollDownAndUp() {
        let coordinator = ScrollSyncCoordinator()
        
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        editorSV.automaticallyAdjustsContentInsets = false
        editorSV.contentInsets = NSEdgeInsetsZero
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = String(repeating: "Line of text\n", count: 80)
        editorSV.documentView = textView
        
        let previewDoc = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        previewSV.documentView = previewDoc
        
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)
        
        // 1. Scroll preview to bottom (3000 - 600 = 2400)
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: 2400))
        coordinator.handlePreviewScrolled()
        
        let effectiveHeight = ScrollSyncCoordinator.effectiveContentHeight(for: textView)
        let expectedEditorMaxY = max(0, effectiveHeight - 600.0)
        let editorAtBottom = editorSV.contentView.bounds.origin.y
        #expect(abs(editorAtBottom - expectedEditorMaxY) < 1.0)
        
        // 2. Now scroll preview BACK UP to 1200 (50% progress)
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: 1200))
        coordinator.handlePreviewScrolled()
        
        let editorAtMid = editorSV.contentView.bounds.origin.y
        let expectedEditorMidY = expectedEditorMaxY * 0.5
        #expect(abs(editorAtMid - expectedEditorMidY) < 1.0)
        
        // 3. Now scroll preview BACK UP to top (0)
        previewSV.contentView.scroll(to: NSPoint(x: 0, y: 0))
        coordinator.handlePreviewScrolled()
        
        let editorAtTop = editorSV.contentView.bounds.origin.y
        #expect(abs(editorAtTop - 0.0) < 1.0)
    }
    
    @Test func testRealViewsScrollSyncBidirectional() {
        let sampleMarkdown = """
        # Elastic at Telenet
        
        #### 1. Security Information and Event Management
        * Splunk: central SIEM
        * CrowdStrike: endpoint
        
        #### 2. Vector Database & AI Solutions
        * Service Activation
        
        #### 3. Observability, Logging, and Metrics
        * Dynatrace
        * Elastic
        
        #### 4. Dedicated Workloads
        * Search
        
        #### 5. Non-IT Scope
        * TV & OTT
        * CDN
        
        Main VP: lara@telenet.be
        """
        
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        editorSV.automaticallyAdjustsContentInsets = false
        editorSV.contentInsets = NSEdgeInsetsZero
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.string = sampleMarkdown
        editorSV.documentView = textView
        
        let previewView = MarkdownPreviewView(markdown: sampleMarkdown)
        let previewHosting = NSHostingView(rootView: previewView)
        previewHosting.frame = NSRect(x: 400, y: 0, width: 400, height: 600)
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(editorSV)
        container.addSubview(previewHosting)
        window.contentView = container
        window.display()
        
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView { return sv }
            for sub in view.subviews {
                if let found = findScrollView(in: sub) { return found }
            }
            return nil
        }
        
        guard let previewSV = findScrollView(in: previewHosting) else {
            #expect(false, "Could not find preview scroll view")
            return
        }
        
        let coordinator = ScrollSyncCoordinator.shared
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)
        
        let previewDocHeight = ScrollSyncCoordinator.effectiveContentHeight(for: previewSV.documentView!)
        let editorDocHeight = ScrollSyncCoordinator.effectiveContentHeight(for: editorSV.documentView!)
        
        #expect(previewDocHeight > 0)
        #expect(editorDocHeight > 0)
        
        let previewMaxScroll = max(0, previewDocHeight - previewSV.contentView.bounds.height)
        let editorMaxScroll = max(0, editorDocHeight - editorSV.contentView.bounds.height)
        
        if previewMaxScroll > 0 && editorMaxScroll > 0 {
            // Scroll preview to bottom
            previewSV.contentView.scroll(to: NSPoint(x: 0, y: previewMaxScroll))
            coordinator.handlePreviewScrolled()
            
            #expect(abs(editorSV.contentView.bounds.origin.y - editorMaxScroll) < 1.0)
            
            // Scroll editor to bottom
            editorSV.contentView.scroll(to: NSPoint(x: 0, y: editorMaxScroll))
            coordinator.handleEditorScrolled()
            
            #expect(abs(previewSV.contentView.bounds.origin.y - previewMaxScroll) < 1.0)
            
            // Scroll preview back up to 0
            previewSV.contentView.scroll(to: NSPoint(x: 0, y: 0))
            coordinator.handlePreviewScrolled()
            #expect(abs(editorSV.contentView.bounds.origin.y - 0.0) < 1.0)
            
            // Scroll editor back up to 0
            editorSV.contentView.scroll(to: NSPoint(x: 0, y: 0))
            coordinator.handleEditorScrolled()
            #expect(abs(previewSV.contentView.bounds.origin.y - 0.0) < 1.0)
        }
    }

    // MARK: - Production Wiring (real views, real notifications)

    private nonisolated static let longMarkdown: String = (1...80).map { index in
        "## Section \(index)\n\nParagraph \(index) with enough words to wrap across the preview column width.\n"
    }.joined(separator: "\n")

    /// Hosts the real editor + preview side by side, exactly as `EditorSplitView` does in `.split` mode.
    private func makeSplitWindow(markdown: String = longMarkdown) -> (window: NSWindow, hosting: NSView, editor: NSScrollView, preview: NSScrollView)? {
        let root = HStack(spacing: 0) {
            MarkdownEditorView(text: .constant(markdown), onSave: {})
                .frame(width: 400)
            MarkdownPreviewView(markdown: markdown)
                .frame(width: 400)
        }
        .frame(width: 800, height: 600)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.display()

        let scrollViews = allScrollViews(in: hosting)
        guard let editor = scrollViews.first(where: { $0.documentView is MarkdownNSTextView }),
              let preview = scrollViews.first(where: { !($0.documentView is NSTextView) }) else {
            return nil
        }
        return (window, hosting, editor, preview)
    }

    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let sv = view as? NSScrollView { found.append(sv) }
        for sub in view.subviews { found.append(contentsOf: allScrollViews(in: sub)) }
        return found
    }

    private func resetShared() -> ScrollSyncCoordinator {
        let coordinator = ScrollSyncCoordinator.shared
        coordinator.unregisterEditor()
        coordinator.unregisterPreview()
        coordinator.isSyncEnabled = true
        return coordinator
    }

    /// Distance scrolled from the top of the (flipped) document, independent of the document frame origin.
    private func topOffset(_ scrollView: NSScrollView) -> CGFloat {
        scrollView.documentVisibleRect.minY
    }

    /// Simulates a trackpad gesture on `scrollView`: live-scroll start, bounds change to `offset`
    /// points below the top of the document (may be out of range to emulate elastic overscroll),
    /// live-scroll end.
    private func liveScroll(_ scrollView: NSScrollView, toOffset offset: CGFloat) {
        let documentTop = scrollView.documentView?.frame.minY ?? 0
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: documentTop + offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    /// Ground-truth text height of the editor, measured straight from TextKit (independent of the coordinator).
    private func editorTextHeight(_ editor: NSScrollView) -> CGFloat {
        guard let textView = editor.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2)
    }

    private func editorMaxOffset(_ editor: NSScrollView) -> CGFloat {
        max(0, editorTextHeight(editor) - editor.contentView.bounds.height)
    }

    private func previewMaxOffset(_ preview: NSScrollView) -> CGFloat {
        max(0, (preview.documentView?.frame.height ?? 0) - preview.contentView.bounds.height)
    }

    /// Regression: text inserted before the text view was attached got laid out while the clip
    /// view was still unflipped, which pushed the document frame origin to y ≈ -8000 and made
    /// every raw scroll offset meaningless (preview frozen, editor scrolled into the void).
    @Test func testEditorDocumentViewStartsAtClipOrigin() {
        _ = resetShared()
        guard let split = makeSplitWindow() else {
            Issue.record("Split hierarchy did not produce editor and preview scroll views")
            return
        }
        defer { split.window.close() }

        let textView = split.editor.documentView!
        #expect(textView.frame.origin == .zero)
        #expect(split.editor.contentView.bounds.origin.y == 0)
        #expect(topOffset(split.editor) == 0)
        #expect(editorMaxOffset(split.editor) > 0)
    }

    @Test func testSplitHierarchyAutoRegistersBothPanes() {
        let coordinator = resetShared()
        guard let split = makeSplitWindow() else {
            Issue.record("Split hierarchy did not produce editor and preview scroll views")
            return
        }
        defer { split.window.close() }

        #expect(coordinator.editorScrollView === split.editor)
        #expect(coordinator.previewScrollView === split.preview)
    }

    @Test func testNotificationDrivenSync() {
        _ = resetShared()
        guard let split = makeSplitWindow() else {
            Issue.record("Split hierarchy did not produce editor and preview scroll views")
            return
        }
        defer { split.window.close() }

        let previewMax = previewMaxOffset(split.preview)
        let editorMax = editorMaxOffset(split.editor)
        #expect(previewMax > 0)
        #expect(editorMax > 0)

        // Preview → editor through the notification path only (no direct handler call).
        liveScroll(split.preview, toOffset: previewMax * 0.5)
        #expect(abs(topOffset(split.editor) - editorMax * 0.5) < 1.0)

        // Editor → preview.
        liveScroll(split.editor, toOffset: editorMax * 0.25)
        #expect(abs(topOffset(split.preview) - previewMax * 0.25) < 1.0)
    }

    @Test func testPreviewElasticOverscrollNeverPushesEditorIntoVoid() {
        _ = resetShared()
        guard let split = makeSplitWindow() else {
            Issue.record("Split hierarchy did not produce editor and preview scroll views")
            return
        }
        defer { split.window.close() }

        let previewMax = previewMaxOffset(split.preview)
        let editorMax = editorMaxOffset(split.editor)
        let textHeight = editorTextHeight(split.editor)

        // Rubber-band 150pt past the bottom of the preview.
        liveScroll(split.preview, toOffset: previewMax + 150)
        #expect(abs(topOffset(split.editor) - editorMax) < 1.0)
        // The editor's visible rect must never extend past the end of its text.
        #expect(split.editor.documentVisibleRect.maxY <= textHeight + 0.5)

        // Rubber-band 80pt above the top of the preview.
        liveScroll(split.preview, toOffset: -80)
        #expect(abs(topOffset(split.editor)) < 0.5)
        #expect(split.editor.documentVisibleRect.minY >= -0.5)
    }

    @Test func testFollowerBoundsChangeIgnoredWhileOtherPaneDrives() {
        let coordinator = ScrollSyncCoordinator()
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        editorSV.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        previewSV.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)

        // Preview gesture in progress (e.g. momentum phase).
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: previewSV)
        #expect(coordinator.activeDriver == .preview)
        previewSV.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1200))
        let previewBefore = previewSV.contentView.bounds.origin.y

        // Editor bounds change that the user did not initiate (layout, leftover momentum, SwiftUI re-layout).
        editorSV.contentView.setBoundsOrigin(NSPoint(x: 0, y: 100))
        #expect(abs(previewSV.contentView.bounds.origin.y - previewBefore) < 0.5)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: previewSV)
        #expect(coordinator.activeDriver == nil)

        // Once the preview gesture ends, an editor gesture drives the preview again.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: editorSV)
        editorSV.contentView.setBoundsOrigin(NSPoint(x: 0, y: 700)) // 50% of 1400
        #expect(abs(previewSV.contentView.bounds.origin.y - 1200) < 1.0) // 50% of 2400
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: editorSV)
    }

    @Test func testLayoutChangeDoesNotDriveEditor() {
        let coordinator = ScrollSyncCoordinator()
        let editorSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewSV = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let previewDoc = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        editorSV.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        previewSV.documentView = previewDoc
        coordinator.registerEditor(editorSV)
        coordinator.registerPreview(previewSV)

        // User scrolls editor to 50%; preview follows.
        editorSV.contentView.scroll(to: NSPoint(x: 0, y: 700))
        coordinator.handleEditorScrolled()
        let editorBefore = editorSV.contentView.bounds.origin.y
        #expect(abs(editorBefore - 700) < 1.0)
        #expect(abs(previewSV.contentView.bounds.origin.y - 1200) < 1.0)

        // Preview re-renders shorter (typing) and AppKit/SwiftUI re-constrains its clip view.
        previewDoc.setFrameSize(NSSize(width: 400, height: 1500))
        previewSV.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))

        // A layout-driven preview bounds change must not yank the editor.
        #expect(abs(editorSV.contentView.bounds.origin.y - editorBefore) < 0.5)
    }

    @Test func testUnregisterOnlyMatchingScrollView() {
        let coordinator = ScrollSyncCoordinator()
        let oldPreview = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let newPreview = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let oldEditor = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let newEditor = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))

        // SwiftUI builds the replacement before dismantling the old view.
        coordinator.registerPreview(oldPreview)
        coordinator.registerPreview(newPreview)
        coordinator.unregisterPreview(oldPreview)
        #expect(coordinator.previewScrollView === newPreview)

        coordinator.registerEditor(oldEditor)
        coordinator.registerEditor(newEditor)
        coordinator.unregisterEditor(oldEditor)
        #expect(coordinator.editorScrollView === newEditor)

        coordinator.unregisterPreview(newPreview)
        coordinator.unregisterEditor(newEditor)
        #expect(coordinator.previewScrollView == nil)
        #expect(coordinator.editorScrollView == nil)
    }

    @Test func testScrollViewFinderRegistersAndReleasesPreview() {
        let coordinator = resetShared()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: AnyView(MarkdownPreviewView(markdown: Self.longMarkdown).frame(width: 400, height: 600)))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // Strong reference: the coordinator's weak pointer can only clear through unregistration.
        guard let preview = allScrollViews(in: hosting).first else {
            Issue.record("Preview scroll view not found")
            return
        }
        #expect(coordinator.previewScrollView === preview)

        // Replacing the content (e.g. switching to Editor-only mode) dismantles the preview,
        // which must release its registration.
        hosting.rootView = AnyView(Color.clear.frame(width: 400, height: 600))
        hosting.layoutSubtreeIfNeeded()
        window.display()
        #expect(coordinator.previewScrollView == nil)
        _ = preview
    }

    // MARK: - Geometry (frame origin, flippedness, content insets)

    @Test func testMetricsIgnoreDocumentFrameOrigin() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let doc = FlippedDocumentView(frame: NSRect(x: 0, y: -8000, width: 400, height: 3000))
        scrollView.documentView = doc
        doc.setFrameOrigin(NSPoint(x: 0, y: -8000))
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: -8000 + 1200))

        let metrics = ScrollMetrics(scrollView)!
        #expect(metrics.offset == 1200)
        #expect(metrics.maxOffset == 2400)
        #expect(metrics.progress == 0.5)
        #expect(metrics.clipOriginY(forOffset: 2400) == CGFloat(-8000 + 2400))
    }

    @Test func testMetricsNonFlippedDocument() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        #expect(scrollView.documentView?.isFlipped == false)

        // Non-flipped: bounds origin y = max (2400) shows the TOP of the document.
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 2400))
        #expect(ScrollMetrics(scrollView)!.progress == 0)

        // Bounds origin y = 0 shows the BOTTOM of the document.
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        let metrics = ScrollMetrics(scrollView)!
        #expect(metrics.progress == 1)
        #expect(metrics.clipOriginY(forOffset: 0) == 2400)
        #expect(metrics.clipOriginY(forOffset: 2400) == 0)
    }

    @Test func testMetricsHonorContentInsets() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 20, right: 0)
        scrollView.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))

        let metrics = ScrollMetrics(scrollView)!
        let visible = scrollView.contentView.bounds.height
        #expect(metrics.minOffset == -52)
        #expect(metrics.maxOffset == 3000 - visible + 20)
        #expect(metrics.clampedOffset(forProgress: 0) == -52)
        #expect(metrics.clampedOffset(forProgress: 1) == 3000 - visible + 20)
        #expect(metrics.clampedOffset(forProgress: 1.7) == metrics.maxOffset)
        #expect(metrics.clampedOffset(forProgress: -0.4) == metrics.minOffset)
    }

    @Test func testMetricsShortDocument() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scrollView.documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let metrics = ScrollMetrics(scrollView)!
        #expect(metrics.progress == 0)
        #expect(metrics.maxOffset == 0)
        #expect(metrics.clampedOffset(forProgress: 0.8) == 0)
    }
}

/// Flipped document view mirroring the geometry of `NSTextView` and SwiftUI's hosted scroll content.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
