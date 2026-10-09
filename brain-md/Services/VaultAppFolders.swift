//
//  VaultAppFolders.swift
//  brain-md
//

import Foundation

/// Vault-root folders that brain-md manages rather than the user: Skills, and the attachments
/// folder when attachments are saved to one fixed folder at the root. The sidebar lists them
/// below a separator, and the 3D graph leaves them out.
extension VaultManager {
    public static let skillsFolderName = "Skills"
    static let attachmentFolderDefaultsKey = "attachment_folder"

    /// App folders in sidebar order.
    public var appFolderNames: [String] {
        Self.appFolderNames(attachmentSetting: UserDefaults.standard.string(forKey: Self.attachmentFolderDefaultsKey))
    }

    /// Whether a vault path is an app folder or inside one.
    public func isInAppFolder(_ relativePath: String) -> Bool {
        Self.isInAppFolder(relativePath, appFolders: appFolderNames)
    }

    /// Note paths outside the app folders: the user's own knowledge, as shown in the 3D graph.
    public func knowledgeNotePaths() -> [String] {
        let appFolders = appFolderNames
        return getAllNotePaths().filter { !Self.isInAppFolder($0, appFolders: appFolders) }
    }

    /// Splits root items into the user's own and the app folders (in `appFolders` order).
    nonisolated static func splitAppFolders(_ items: [NoteItem], appFolders: [String]) -> (user: [NoteItem], app: [NoteItem]) {
        let isAppFolder = { (item: NoteItem) in item.isDirectory && isInAppFolder(item.relativePath, appFolders: appFolders) }
        let app = appFolders.compactMap { name in
            items.first { isAppFolder($0) && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (items.filter { !isAppFolder($0) }, app)
    }

    /// The attachments setting names a root folder only when it's a single folder name ("Attachments");
    /// empty (next to the note), "./…" (relative to the note) and nested paths aren't app folders.
    nonisolated static func appFolderNames(attachmentSetting: String?) -> [String] {
        var names = [skillsFolderName]
        let setting = (attachmentSetting ?? "Attachments")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !setting.isEmpty, !setting.hasPrefix("."), !setting.contains("/"),
           setting.caseInsensitiveCompare(skillsFolderName) != .orderedSame {
            names.append(setting)
        }
        return names
    }

    /// Compares the first path component, ignoring case like the macOS file system does.
    nonisolated static func isInAppFolder(_ relativePath: String, appFolders: [String]) -> Bool {
        let first = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return appFolders.contains { $0.caseInsensitiveCompare(first) == .orderedSame }
    }
}
