//
//  SkillsTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

@MainActor
struct SkillsTests {

    // MARK: - Parsing

    @Test func skillFileIsParsedFromFrontmatterAndBody() throws {
        let skill = try #require(Skill.parse("""
            ---
            name: Translate to Dutch
            description: Translates the note
            icon: globe
            show-in: [chat]
            uses-note: true
            order: 7
            ---
            Translate {{note}} into Dutch.
            """, relativePath: "Skills/Translate.md"))
        #expect(skill.name == "Translate to Dutch")
        #expect(skill.summary == "Translates the note")
        #expect(skill.icon == "globe")
        #expect(skill.placements == [.chat])
        #expect(skill.usesNote)
        #expect(skill.order == 7)
        #expect(skill.instructions == "Translate {{note}} into Dutch.")
        #expect(skill.id == "Skills/Translate.md")
    }

    @Test func missingFieldsFallBackToSensibleDefaults() throws {
        let skill = try #require(Skill.parse("Explain this note to a newcomer.", relativePath: "Skills/Explain Simply.md"))
        #expect(skill.name == "Explain Simply")
        #expect(skill.icon == "sparkles")
        #expect(skill.placements == [.menu, .chat])
        #expect(skill.usesNote)
        #expect(skill.order == 100)
    }

    @Test func placementsAndNoteUseAreReadFromTheirValues() throws {
        func skill(_ frontmatter: String) throws -> Skill {
            try #require(Skill.parse("---\n\(frontmatter)\n---\nDo it.", relativePath: "Skills/x.md"))
        }
        #expect(try skill("show-in: menu").placements == [.menu])
        #expect(try skill("show-in: [Menu, CHAT]").placements == [.menu, .chat])
        #expect(try skill("show-in: [nowhere]").placements.isEmpty) // hidden
        #expect(try skill("show-in:\n  - chat").placements == [.chat])
        #expect(try !skill("uses-note: false").usesNote)
        #expect(try !skill("uses-note: no").usesNote)
        #expect(try skill("uses-note: yes").usesNote)
    }

    @Test func skillWithoutAPromptIsSkipped() {
        #expect(Skill.parse("---\nname: Empty\n---\n  \n", relativePath: "Skills/Empty.md") == nil)
    }

    // MARK: - Prompts

    @Test func noteIsAppendedOrPlacedAtThePlaceholder() throws {
        let appended = try #require(Skill.parse("Summarize this.", relativePath: "Skills/a.md"))
        #expect(try appended.prompt(note: "  Ship v2 on Friday. ") == "Summarize this.\n\nNote:\n\nShip v2 on Friday.")

        let placed = try #require(Skill.parse("Read {{note}} and reply in one line.", relativePath: "Skills/b.md"))
        #expect(try placed.prompt(note: "Ship v2") == "Read Ship v2 and reply in one line.")
        #expect(placed.chatMessage == "Read the note and reply in one line.")

        #expect(throws: GemmaServiceError.emptyInput) { try appended.prompt(note: " \n") }
    }

    @Test func skillThatDoesNotUseTheNoteIgnoresIt() throws {
        let skill = try #require(Skill.parse("---\nuses-note: false\n---\nGive me a writing prompt.", relativePath: "Skills/c.md"))
        #expect(try skill.prompt(note: "") == "Give me a writing prompt.")
        #expect(try skill.prompt(note: "Secret note") == "Give me a writing prompt.")
    }

    @Test func skillsSortByOrderThenName() throws {
        let skills = try ["---\norder: 2\n---\nB", "---\norder: 1\n---\nZ", "---\norder: 2\n---\nA"]
            .enumerated()
            .map { try #require(Skill.parse($1, relativePath: "Skills/\(["b", "z", "a"][$0]).md")) }
        #expect(Skill.sorted(skills).map(\.name) == ["z", "a", "b"])
    }

    @Test func defaultSkillsAndTheTemplateParse() throws {
        let defaults = try SkillLibrary.defaultSkills.map {
            try #require(Skill.parse($0.markdown, relativePath: "Skills/\($0.fileName)"))
        }
        #expect(defaults.map(\.name) == [
            "Summarize Note", "Extract Action Items", "Polish & Rewrite",
            "List the Open Questions", "Suggest a Better Title",
        ])
        let menuSkills = defaults.filter { $0.placements.contains(.menu) }
        #expect(menuSkills.count == 3)
        let allUseNote = defaults.allSatisfy { $0.usesNote }
        #expect(allUseNote)
        #expect(defaults[0].instructions.contains("**Decisions**"))

        let template = try #require(Skill.parse(SkillLibrary.template(name: "New Skill"), relativePath: "Skills/New Skill.md"))
        #expect(template.name == "New Skill")
        #expect(template.placements == [.menu, .chat])
        #expect(template.order == 50)
    }

    // MARK: - Library

    /// Regression: the test host is the real app with the user's settings, and used to write the
    /// default skills into the user's own vault at launch.
    @Test func testHostNeverSeedsTheUsersVault() {
        #expect(SkillLibrary.isHostingTests)
    }

    private func makeLibrary() throws -> (SkillLibrary, VaultManager, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrainSkillsVault_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vault = VaultManager(customVaultURL: directory)
        let defaults = try #require(UserDefaults(suiteName: "brainmd-tests-\(UUID().uuidString)"))
        return (SkillLibrary(vault: vault, defaults: defaults), vault, directory, defaults)
    }

    @Test func defaultsAreWrittenOnceSoDeletingOneSticks() throws {
        let (library, _, directory, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }

        library.seedDefaultsIfNeeded()
        #expect(library.skills.count == 5)

        let summarize = library.folderURL.appendingPathComponent("Summarize Note.md")
        try FileManager.default.removeItem(at: summarize)
        library.seedDefaultsIfNeeded()
        library.reload()
        #expect(library.skills.count == 4)
        #expect(!library.skills.contains { $0.name == "Summarize Note" })
    }

    @Test func restoreDefaultsAddsMissingFilesAndKeepsEdits() throws {
        let (library, _, directory, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try library.restoreDefaults()

        let actionItems = library.folderURL.appendingPathComponent("Extract Action Items.md")
        try Data("---\nname: My Tasks\n---\nOnly my tasks.".utf8).write(to: actionItems)
        try FileManager.default.removeItem(at: library.folderURL.appendingPathComponent("Better Title.md"))

        try library.restoreDefaults()
        #expect(library.skills.count == 5)
        #expect(library.skills.contains { $0.name == "My Tasks" })
        #expect(library.skills.contains { $0.name == "Suggest a Better Title" })
    }

    @Test func newSkillsGetUniqueNamesAndAppearInTheVault() throws {
        let (library, vault, directory, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try library.createSkill() == "Skills/New Skill.md")
        #expect(try library.createSkill() == "Skills/New Skill 2.md")
        #expect(library.skills.map(\.name) == ["New Skill", "New Skill 2"])
        #expect(vault.rootItems.contains { $0.isDirectory && $0.name == "Skills" })
    }

    @Test func filesWithoutAPromptOrMarkdownExtensionAreIgnored() throws {
        let (library, _, directory, _) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: library.folderURL, withIntermediateDirectories: true)
        try Data("---\nname: Empty\n---\n".utf8).write(to: library.folderURL.appendingPathComponent("Empty.md"))
        try Data("Not a skill".utf8).write(to: library.folderURL.appendingPathComponent("notes.txt"))
        try Data("Works.".utf8).write(to: library.folderURL.appendingPathComponent("Real.md"))

        library.reload()
        #expect(library.skills.map(\.name) == ["Real"])
        #expect(library.skills(for: .menu).map(\.name) == ["Real"])
    }
}
