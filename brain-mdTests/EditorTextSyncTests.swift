//
//  EditorTextSyncTests.swift
//  brain-mdTests
//

import AppKit
import SwiftUI
import Testing
@testable import brain_md

/// The editor copies typing into its binding ~90 ms after a keystroke. Within that window the
/// text view and the binding differ, which must not be mistaken for a change from outside.
@MainActor
struct EditorTextSyncTests {
    private final class Box { var text: String; init(_ text: String) { self.text = text } }

    private func makeEditor(_ box: Box) -> (MacMarkdownEditorView.Coordinator, MarkdownNSTextView) {
        let view = MacMarkdownEditorView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            currentTheme: ThemeManager.resolveTheme(for: .light), fontSize: 14, fontDesign: "monospaced",
            onSave: {}, onImageDroppedOrPasted: nil)
        let coordinator = view.makeCoordinator()
        let textView = MarkdownNSTextView()
        textView.delegate = coordinator
        textView.string = box.text
        return (coordinator, textView)
    }

    private func type(_ text: String, in textView: MarkdownNSTextView, _ coordinator: MacMarkdownEditorView.Coordinator) {
        textView.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    private func waitPastSync() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test func aPendingSyncDoesNotOverwriteTheNextNote() async throws {
        let box = Box("# A")
        let (coordinator, textView) = makeEditor(box)
        type("# A typed", in: textView, coordinator)

        box.text = "# B" // another note opens before the keystroke synced
        coordinator.showText(box.text, in: textView)
        try await waitPastSync()

        #expect(box.text == "# B")
        #expect(textView.string == "# B")
    }

    @Test func aRedrawBeforeTheSyncKeepsTheKeystroke() async throws {
        let box = Box("# A")
        let (coordinator, textView) = makeEditor(box)
        type("# A typed", in: textView, coordinator)

        coordinator.showText(box.text, in: textView) // re-render while the binding still has "# A"
        #expect(textView.string == "# A typed")
        try await waitPastSync()
        #expect(box.text == "# A typed")
    }

    @Test func typingStillSyncsAndOutsideChangesStillShow() async throws {
        let box = Box("# A")
        let (coordinator, textView) = makeEditor(box)
        type("# A typed", in: textView, coordinator)
        try await waitPastSync()
        #expect(box.text == "# A typed")

        box.text = "# A typed\n- line from a transcript"
        coordinator.showText(box.text, in: textView)
        #expect(textView.string == "# A typed\n- line from a transcript")
    }
}
