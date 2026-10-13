//
//  SidebarOrder.swift
//  brain-md
//
//  How the sidebar orders notes and folders: a sort mode (sidebar_sort_mode), folders or notes
//  first (sidebar_folders_first), and the custom order you drag, kept in the vault in
//  .brain-md/sidebar-order.json so it syncs with the vault.
//

import Foundation

enum SidebarSortMode: String, CaseIterable, Identifiable {
    case custom, name, modified, created

    static let key = "sidebar_sort_mode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: "Custom"
        case .name: "Name"
        case .modified: "Date Modified"
        case .created: "Date Created"
        }
    }
}

enum SidebarOrder {
    static let foldersFirstKey = "sidebar_folders_first"

    /// `items` and their children in sidebar order: grouped into folders and notes as `foldersFirst`
    /// says, then by `mode`. In custom mode `custom[folder]` lists file names in order (`""` is the
    /// vault root); anything not listed, like a new note, follows them by name.
    static func sorted(
        _ items: [NoteItem], mode: SidebarSortMode, foldersFirst: Bool, custom: [String: [String]], folder: String = ""
    ) -> [NoteItem] {
        let rank = Dictionary((custom[folder] ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func byName(_ a: NoteItem, _ b: NoteItem) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return items.map { item in
            var item = item
            if let children = item.children {
                item.children = sorted(children, mode: mode, foldersFirst: foldersFirst, custom: custom, folder: item.relativePath)
            }
            return item
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory == foldersFirst }
            switch mode {
            case .name:
                return byName(a, b)
            case .modified:
                return a.modifiedAt != b.modifiedAt ? a.modifiedAt > b.modifiedAt : byName(a, b)
            case .created:
                return a.createdAt != b.createdAt ? a.createdAt > b.createdAt : byName(a, b)
            case .custom:
                switch (rank[a.url.lastPathComponent], rank[b.url.lastPathComponent]) {
                case let (x?, y?): return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return byName(a, b)
                }
            }
        }
    }
}

extension VaultManager {
    var customOrderURL: URL { vaultURL.appendingPathComponent(".brain-md/sidebar-order.json") }

    /// Reads the vault's custom order; a missing or unreadable file means no custom order yet.
    func loadCustomOrder() {
        customOrder = (try? Data(contentsOf: customOrderURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    /// Writes the custom order, dropping names of files and folders that no longer exist.
    func saveCustomOrder() {
        let fm = FileManager.default
        var pruned: [String: [String]] = [:]
        for (folder, names) in customOrder {
            let folderURL = folder.isEmpty ? vaultURL : vaultURL.appendingPathComponent(folder)
            let existing = names.filter { fm.fileExists(atPath: folderURL.appendingPathComponent($0).path) }
            if !existing.isEmpty { pruned[folder] = existing }
        }
        customOrder = pruned
        guard !pruned.isEmpty || fm.fileExists(atPath: customOrderURL.path) else { return }
        do {
            try fm.createDirectory(at: customOrderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(pruned).write(to: customOrderURL, options: .atomic)
        } catch {
            logActivity(action: "Couldn't Save Sidebar Order", detail: error.localizedDescription, isError: true)
        }
    }

    /// Places the item at `source` right before `target` in the custom order, moving it into
    /// `target`'s folder first if it's elsewhere. The folder starts from the order shown now
    /// (`mode`, `foldersFirst`), so switching to Custom keeps what you saw.
    func moveInOrder(_ source: String, before target: NoteItem, mode: SidebarSortMode, foldersFirst: Bool) throws {
        guard source != target.relativePath else { return }
        let folder = (target.relativePath as NSString).deletingLastPathComponent
        if (source as NSString).deletingLastPathComponent != folder {
            try moveItem(sourceRelativePath: source, toDirectoryRelativePath: folder)
        }
        // shortcut: a move that had to rename the item (name taken) keeps its default place, rare enough to leave.
        let name = (source as NSString).lastPathComponent
        let siblings = folder.isEmpty ? rootItems : noteItem(atRelativePath: folder)?.children ?? []
        guard siblings.contains(where: { $0.url.lastPathComponent == name }) else { return }
        var order = SidebarOrder.sorted(siblings, mode: mode, foldersFirst: foldersFirst, custom: customOrder, folder: folder)
            .map(\.url.lastPathComponent)
        order.removeAll { $0 == name }
        order.insert(name, at: order.firstIndex(of: target.url.lastPathComponent) ?? order.endIndex)
        customOrder[folder] = order
        saveCustomOrder()
    }

    /// Keeps the custom order in step after a rename or move: a renamed item keeps its place, a
    /// moved one leaves its old folder's list, and a folder takes its own order along.
    func customOrderItemMoved(from old: String, to new: String) {
        guard !customOrder.isEmpty, old != new else { return }
        let oldFolder = (old as NSString).deletingLastPathComponent
        let oldName = (old as NSString).lastPathComponent
        if oldFolder == (new as NSString).deletingLastPathComponent {
            let newName = (new as NSString).lastPathComponent
            customOrder[oldFolder] = customOrder[oldFolder]?.map { $0 == oldName ? newName : $0 }
        } else {
            customOrder[oldFolder]?.removeAll { $0 == oldName }
        }
        for key in customOrder.keys where key == old || key.hasPrefix(old + "/") {
            customOrder[new + key.dropFirst(old.count)] = customOrder.removeValue(forKey: key)
        }
        saveCustomOrder()
    }
}
