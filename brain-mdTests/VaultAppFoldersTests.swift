//
//  VaultAppFoldersTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

@MainActor
struct VaultAppFoldersTests {

    @Test func attachmentsFolderIsAnAppFolderOnlyWhenItIsOneRootFolder() {
        #expect(VaultManager.appFolderNames(attachmentSetting: nil) == ["Skills", "Attachments"])
        #expect(VaultManager.appFolderNames(attachmentSetting: " /Files/ ") == ["Skills", "Files"])
        #expect(VaultManager.appFolderNames(attachmentSetting: "") == ["Skills"])           // next to the note
        #expect(VaultManager.appFolderNames(attachmentSetting: "./assets") == ["Skills"])   // relative to the note
        #expect(VaultManager.appFolderNames(attachmentSetting: "Media/Images") == ["Skills"])
        #expect(VaultManager.appFolderNames(attachmentSetting: "skills") == ["Skills"])
    }

    @Test func appFolderMembershipUsesTheFirstPathComponent() {
        let folders = ["Skills", "Attachments"]
        #expect(VaultManager.isInAppFolder("Skills/Summarize Note.md", appFolders: folders))
        #expect(VaultManager.isInAppFolder("attachments/image.png", appFolders: folders))
        #expect(VaultManager.isInAppFolder("Skills", appFolders: folders))
        #expect(!VaultManager.isInAppFolder("Skills.md", appFolders: folders))
        #expect(!VaultManager.isInAppFolder("Projects/Skills/plan.md", appFolders: folders))
    }

    @Test func sidebarListsAppFoldersSeparatelyInFixedOrder() {
        func folder(_ name: String) -> NoteItem {
            NoteItem(name: name, relativePath: name, url: URL(fileURLWithPath: "/v/\(name)"), isDirectory: true, children: [])
        }
        let note = NoteItem(name: "Skills", relativePath: "Skills.md", url: URL(fileURLWithPath: "/v/Skills.md"), isDirectory: false)
        let items = [folder("Attachments"), folder("Projects"), folder("Skills"), note]

        let split = VaultManager.splitAppFolders(items, appFolders: ["Skills", "Attachments"])
        #expect(split.user.map(\.relativePath) == ["Projects", "Skills.md"])
        #expect(split.app.map(\.name) == ["Skills", "Attachments"])
    }

    @Test func graphLeavesOutSkillsAndAttachments() throws {
        let key = VaultManager.attachmentFolderDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrainAppFoldersVault_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = VaultManager(customVaultURL: directory)
        try vault.createFile(relativePath: "Projects/Launch.md", content: "# Launch")
        try vault.createFile(relativePath: "Skills/Summarize.md", content: "Summarize.")
        try vault.createFile(relativePath: "Attachments/readme.md", content: "Files")

        let all = Set(vault.getAllNotePaths())
        let knowledge = Set(vault.knowledgeNotePaths())
        #expect(all.isSuperset(of: ["Projects/Launch.md", "Skills/Summarize.md", "Attachments/readme.md"]))
        #expect(knowledge == all.subtracting(["Skills/Summarize.md", "Attachments/readme.md"]))
        #expect(knowledge.contains("Projects/Launch.md"))
    }
}
