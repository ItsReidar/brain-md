//
//  EditorSession.swift
//  brain-md
//
//  One editor window's state: the note it shows and its unsaved edits. Each window (a native tab
//  is a window) owns a session; VaultManager's editor properties act on the frontmost one.
//

import AppKit
import Combine
import Foundation

@MainActor
public final class EditorSession: ObservableObject {
    @Published public var selectedItem: NoteItem? {
        didSet {
            if oldValue?.url != selectedItem?.url { onNoteChange?(oldValue) }
        }
    }
    @Published public var editorContent = ""
    @Published public var editorTitle = ""
    @Published public var hasUnsavedChanges = false

    /// Set while something else is writing into the note (a meeting transcript); auto-save waits
    /// until it's cleared and `scheduleAutosave()` runs again.
    public var isAutosaveSuspended = false
    var autosaveTask: Task<Void, Never>?

    /// The window showing this session; nil until it's on screen, and in tests.
    weak var window: NSWindow?
    /// Claimed by a window, so the next window gets a session of its own.
    var isClaimed = false
    var onNoteChange: ((NoteItem?) -> Void)?
    var closeObserver: NSObjectProtocol?

    nonisolated init() {}
}

/// The value a note window opens with: a vault-relative path, an absolute path for a file outside
/// the vault, or nil for an empty window. The id keeps two requests for one note apart.
public struct NoteWindowRequest: Codable, Hashable, Sendable {
    public var path: String?
    public var id = UUID()

    public init(path: String?) { self.path = path }
}
