//
//  VaultManaging.swift
//  brain-md
//

import Foundation

@MainActor
public protocol VaultManaging: AnyObject {
    var vaultURL: URL { get }
    var rootItems: [NoteItem] { get }
    var selectedItem: NoteItem? { get set }
    var editorContent: String { get set }
    var editorTitle: String { get set }
    var searchQuery: String { get set }
    var hasUnsavedChanges: Bool { get set }
    var recentActivities: [ActivityLog] { get }
    var totalNotesCount: Int { get }
    var allTags: [String: Int] { get }
    var selectedTag: String? { get set }
    var showingNewNotePrompt: Bool { get set }
    var newNotePromptDefaultName: String { get set }
    
    func setVaultURL(_ newURL: URL)
    func refreshFiles()
    func selectNote(_ item: NoteItem)
    func selectNote(byRelativePath path: String)
    func generateUniqueNotePath(baseName: String) -> String
    func saveCurrentNote()
    func promptNewNote()
    func createNote(named name: String) throws -> String
    func createNoteFromTemplate() throws -> String
    func getNotes(taggedWith tag: String) -> [NoteItem]
    
    func readFile(relativePath: String) throws -> String
    func createFile(relativePath: String, content: String) throws
    func writeFile(relativePath: String, content: String) throws
    func appendFile(relativePath: String, contentToAppend: String) throws
    func deleteFile(relativePath: String) throws
    func createFolder(relativePath: String) throws
    func renameItem(oldRelativePath: String, newName: String) throws
    func moveItem(sourceRelativePath: String, toDirectoryRelativePath: String) throws
    func moveItem(sourceRelativePath: String, intoContainerOf item: NoteItem) throws
    
    func searchNotes(query: String) -> [NoteSearchResult]
    func getAllNotePaths() -> [String]
    func getStats() -> [String: AnyCodableValue]
    func logActivity(action: String, detail: String, isError: Bool)
}
