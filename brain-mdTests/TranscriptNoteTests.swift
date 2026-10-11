//
//  TranscriptNoteTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

/// Transcript lines go to the note the recording started in, even after switching notes
/// (transcription keeps finishing the captured audio once a switch stops the recording).
@MainActor
struct TranscriptNoteTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("brainmd-transcript-\(UUID().uuidString)")
    private var vaultURL: URL { root.appendingPathComponent("Vault") }
    private var outsideURL: URL { root.appendingPathComponent("Downloads/minutes.md") }

    private func setUp() throws -> VaultManager {
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Sync".write(to: vaultURL.appendingPathComponent("sync.md"), atomically: true, encoding: .utf8)
        try "# Other".write(to: vaultURL.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        try "# Minutes".write(to: outsideURL, atomically: true, encoding: .utf8)
        return VaultManager(customVaultURL: vaultURL)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func segment(_ text: String, at timestamp: Double) -> TranscriptionSegment {
        TranscriptionSegment(speaker: .systemAudio, speakerIndex: 0, timestamp: timestamp, duration: 3, text: text, isFinal: true)
    }

    @Test func linesAfterANoteSwitchStayInTheRecordedNote() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "sync.md")
        let noteURL = try #require(vault.selectedItem?.url)
        var writer = TranscriptWriter()

        vault.editNote(at: noteURL) { writer.write(segment("We slip two weeks.", at: 192), into: &$0) }
        #expect(vault.editorContent == "# Sync\n- **Speaker 1** [03:12] We slip two weeks.")

        vault.selectNote(byRelativePath: "other.md") // saves sync.md, stops the recording
        vault.editNote(at: noteURL) { writer.write(segment("Certification failed.", at: 196), into: &$0) }

        #expect(vault.editorContent == "# Other")
        #expect(!vault.hasUnsavedChanges)
        #expect(try read(vaultURL.appendingPathComponent("other.md")) == "# Other")
        #expect(try read(vaultURL.appendingPathComponent("sync.md"))
            == "# Sync\n- **Speaker 1** [03:12] We slip two weeks. Certification failed.")
    }

    @Test func linesAfterSwitchingAwayFromAnOutsideFileGoToThatFile() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.openFile(at: outsideURL)
        let noteURL = try #require(vault.selectedItem?.url)
        var writer = TranscriptWriter()

        vault.selectNote(byRelativePath: "other.md")
        vault.editNote(at: noteURL) { writer.write(segment("Hello.", at: 1), into: &$0) }

        #expect(vault.editorContent == "# Other")
        #expect(try read(outsideURL) == "# Minutes\n- **Speaker 1** [00:01] Hello.")
        #expect(!FileManager.default.fileExists(atPath: vaultURL.appendingPathComponent("minutes.md").path))
    }

    @Test func switchingBackKeepsWritingInTheEditor() throws {
        let vault = try setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        vault.selectNote(byRelativePath: "sync.md")
        let noteURL = try #require(vault.selectedItem?.url)
        var writer = TranscriptWriter()

        vault.selectNote(byRelativePath: "other.md")
        vault.editNote(at: noteURL) { writer.write(segment("We slip two weeks.", at: 192), into: &$0) }
        vault.selectNote(byRelativePath: "sync.md")
        vault.editNote(at: noteURL) { writer.write(segment("Certification failed.", at: 196), into: &$0) }

        #expect(vault.editorContent == "# Sync\n- **Speaker 1** [03:12] We slip two weeks. Certification failed.")
        #expect(vault.hasUnsavedChanges)
    }
}
