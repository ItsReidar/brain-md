//
//  NoteTabs.swift
//  brain-md
//
//  Notes open in tabs above the editor. The editor shows one note at a time: the active tab is
//  always `selectedItem`. Picking a note normally replaces the active tab; "Open in New Tab" adds one.
//

import Foundation

extension VaultManager {
    /// Opens `item` in a tab of its own, or switches to its tab if it's already open.
    public func openInNewTab(_ item: NoteItem) {
        if !tabs.contains(where: { $0.url == item.url }) { tabs.append(item) }
        showTab(item)
    }

    public func showTab(_ item: NoteItem) {
        guard item.url != selectedItem?.url else { return }
        if item.isExternal {
            openFile(at: item.url)
        } else {
            selectNote(byRelativePath: item.relativePath)
        }
        // A note deleted or moved while its tab was in the background can't be shown; drop its tab.
        if selectedItem?.url != item.url { tabs.removeAll { $0.url == item.url } }
    }

    /// Closes a tab, saving it first; closing the active tab shows the next one (or the previous).
    public func closeTab(_ item: NoteItem) {
        guard let index = tabs.firstIndex(where: { $0.url == item.url }) else { return }
        tabs.remove(at: index)
        guard item.url == selectedItem?.url else {
            trashIfUnwritten(item.url)
            return
        }
        if let next = tabs.indices.contains(index) ? tabs[index] : tabs.last {
            showTab(next)
        } else {
            if hasUnsavedChanges { saveCurrentNote() }
            selectedItem = nil
            editorContent = ""
            editorTitle = ""
        }
    }

    /// Called whenever the shown note changes: keeps the tabs in step, and trashes a note that's no
    /// longer open anywhere if the `brain` command created it and nothing was written to it.
    func selectedItemChanged(from old: NoteItem?) {
        if let new = selectedItem {
            if !tabs.contains(where: { $0.url == new.url }) {
                if let old, let index = tabs.firstIndex(where: { $0.url == old.url }) {
                    tabs[index] = new
                } else {
                    tabs.append(new)
                }
            }
        } else if let old {
            tabs.removeAll { $0.url == old.url }
        }
        if let old, !tabs.contains(where: { $0.url == old.url }) { trashIfUnwritten(old.url) }
    }
}
