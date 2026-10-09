//
//  Skills.swift
//  brain-md
//
//  Skills are saved Gemma prompts, stored as Markdown files in the vault's Skills folder so they
//  sync with the notes and can be edited in brain-md itself. The frontmatter says where a skill
//  appears; the body is the prompt.
//

import Combine
import Foundation
import os

/// One saved prompt, parsed from `Skills/<name>.md`.
///
/// ```markdown
/// ---
/// name: Summarize Note
/// description: Meeting-style minutes
/// icon: text.alignleft          # an SF Symbol name
/// show-in: [menu, chat]         # the ✨ menu, the chat window, or both
/// uses-note: true               # adds the open note to the prompt
/// order: 1                      # lower comes first
/// ---
/// Summarize the following as meeting minutes …
/// ```
///
/// With `uses-note: true` the note is appended to the prompt, or placed where `{{note}}` appears.
public struct Skill: Identifiable, Equatable, Sendable {
    public enum Placement: String, CaseIterable, Sendable {
        case menu, chat
    }

    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    public let summary: String
    public let icon: String
    public let placements: Set<Placement>
    public let usesNote: Bool
    public let order: Int
    /// The prompt: the file's body.
    public let instructions: String

    static let notePlaceholder = "{{note}}"
    static let defaultIcon = "sparkles"

    /// Parses a skill file. Returns nil when the body (the prompt) is empty.
    public static func parse(_ markdown: String, relativePath: String) -> Skill? {
        let (frontmatter, body) = FrontmatterParser.parse(markdown)
        let instructions = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return nil }

        var values: [String: String] = [:]
        for property in frontmatter?.properties ?? [] {
            values[property.key.lowercased()] = property.value.trimmingCharacters(in: .whitespaces)
        }
        let fileName = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let placements = values["show-in"].map { value in
            Set(value.lowercased().split(separator: ",").compactMap {
                Placement(rawValue: $0.trimmingCharacters(in: .whitespaces))
            })
        } ?? Set(Placement.allCases)

        return Skill(
            relativePath: relativePath,
            name: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fileName,
            summary: values["description"] ?? "",
            icon: values["icon"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultIcon,
            placements: placements,
            usesNote: values["uses-note"].map { !["false", "no", "0"].contains($0.lowercased()) } ?? true,
            order: values["order"].flatMap(Int.init) ?? 100,
            instructions: instructions)
    }

    /// The prompt for the ✨ menu: the instructions with the note added when the skill uses it.
    public func prompt(note: String) throws -> String {
        guard usesNote else { return instructions.replacingOccurrences(of: Self.notePlaceholder, with: "") }
        let note = GemmaService.trimmed(note)
        guard !note.isEmpty else { throw GemmaServiceError.emptyInput }
        if instructions.contains(Self.notePlaceholder) {
            return instructions.replacingOccurrences(of: Self.notePlaceholder, with: note)
        }
        return "\(instructions)\n\nNote:\n\n\(note)"
    }

    /// The message sent in chat, where the note travels separately (with the note chip).
    public var chatMessage: String {
        instructions.replacingOccurrences(of: Self.notePlaceholder, with: "the note")
    }

    /// Menu order: `order`, then name.
    static func sorted(_ skills: [Skill]) -> [Skill] {
        skills.sorted {
            $0.order != $1.order ? $0.order < $1.order
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Library

/// The skills in the current vault, reloaded whenever the vault's files change.
public final class SkillLibrary: ObservableObject {
    public static let shared = SkillLibrary(vault: .shared)

    @Published public private(set) var skills: [Skill] = []

    /// Unit tests run inside the app with the user's settings; they must not write into the real vault.
    static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Vault paths whose default skills were already written, so deleting one isn't undone.
    static let seededVaultsKey = "ai_skills_seeded_vaults"

    private let vault: VaultManager
    private let defaults: UserDefaults
    private var observer: AnyCancellable?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "brain-md", category: "Skills")

    init(vault: VaultManager, defaults: UserDefaults = .standard) {
        self.vault = vault
        self.defaults = defaults
        observer = vault.$rootItems.sink { [weak self] _ in
            // `$rootItems` publishes before the property changes; read the files afterwards.
            Task { @MainActor in
                guard let self else { return }
                if self.defaults.bool(forKey: LocalModelManager.enabledDefaultsKey), !Self.isHostingTests {
                    self.seedDefaultsIfNeeded()
                }
                self.reload()
            }
        }
    }

    public var folderURL: URL {
        vault.vaultURL.appendingPathComponent(VaultManager.skillsFolderName, isDirectory: true)
    }

    public func skills(for placement: Skill.Placement) -> [Skill] {
        skills.filter { $0.placements.contains(placement) }
    }

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let loaded = files
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> Skill? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let relativePath = "\(VaultManager.skillsFolderName)/\(url.lastPathComponent)"
                guard let skill = Skill.parse(text, relativePath: relativePath) else {
                    log.info("Skipped \(url.lastPathComponent, privacy: .public): no prompt")
                    return nil
                }
                return skill
            }
        let sorted = Skill.sorted(loaded)
        if sorted != skills { skills = sorted }
    }

    /// Writes the default skills the first time on-device AI is used with this vault.
    public func seedDefaultsIfNeeded() {
        let seeded = defaults.stringArray(forKey: Self.seededVaultsKey) ?? []
        let vaultPath = vault.vaultURL.path
        guard !seeded.contains(vaultPath) else { return }
        // Marked first: writing the files refreshes the vault, which calls back into here.
        defaults.set(seeded + [vaultPath], forKey: Self.seededVaultsKey)
        do {
            try restoreDefaults()
        } catch {
            defaults.set(seeded, forKey: Self.seededVaultsKey)
            log.error("Couldn't write default skills: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes any default skill whose file is missing; edited skills are left alone.
    public func restoreDefaults() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for (fileName, markdown) in Self.defaultSkills {
            let url = folderURL.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: url.path) {
                try Data(markdown.utf8).write(to: url, options: .atomic)
            }
        }
        vault.refreshFiles()
        reload()
    }

    /// Creates "New Skill.md" (or "New Skill 2.md", …) from a commented template; returns its vault path.
    @discardableResult
    public func createSkill() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var name = "New Skill"
        var counter = 2
        while fm.fileExists(atPath: folderURL.appendingPathComponent("\(name).md").path) {
            name = "New Skill \(counter)"
            counter += 1
        }
        try Data(Self.template(name: name).utf8).write(
            to: folderURL.appendingPathComponent("\(name).md"), options: .atomic)
        vault.refreshFiles()
        reload()
        return "\(VaultManager.skillsFolderName)/\(name).md"
    }

    // MARK: - Contents

    static func template(name: String) -> String {
        """
        ---
        name: \(name)
        description: What this skill does
        # An SF Symbol name, see the SF Symbols app.
        icon: sparkles
        # Where it appears: menu (the ✨ menu), chat (the chat window), or both.
        show-in: [menu, chat]
        # true adds the open note to the prompt (where {{note}} appears, or at the end).
        uses-note: true
        order: 50
        ---
        Describe what Gemma should do with the note here.
        """
    }

    static let defaultSkills: [(fileName: String, markdown: String)] = [
        ("Summarize Note.md", """
            ---
            name: Summarize Note
            description: Meeting-style minutes with decisions and action items
            icon: text.alignleft
            show-in: [menu, chat]
            uses-note: true
            order: 1
            ---
            Summarize the following as meeting minutes with these sections: **Summary** (2–4 sentences), \
            **Decisions**, **Action items** (a Markdown checklist with owners and dates when mentioned) and \
            **Open questions**. Leave out any section with nothing to report. Don't invent facts.
            """),
        ("Extract Action Items.md", """
            ---
            name: Extract Action Items
            description: A checklist of every task in the note
            icon: checklist
            show-in: [menu, chat]
            uses-note: true
            order: 2
            ---
            List every action item in this note as a Markdown checklist (`- [ ] …`). Include the owner and \
            due date when the note mentions them. If there are none, reply with "No action items found." \
            Don't invent tasks.
            """),
        ("Polish and Rewrite.md", """
            ---
            name: Polish & Rewrite
            description: Fixes grammar and structure, keeping every fact
            icon: wand.and.stars
            show-in: [menu]
            uses-note: true
            order: 3
            ---
            Rewrite this note so it reads clearly: fix grammar and spelling, tighten wording and improve \
            structure. Keep every fact, link, code block, front matter and Markdown heading level. Return only \
            the rewritten note.
            """),
        ("Open Questions.md", """
            ---
            name: List the Open Questions
            description: What the note leaves unanswered
            icon: questionmark.bubble
            show-in: [chat]
            uses-note: true
            order: 4
            ---
            What questions does this note leave open? List them as bullet points, most important first.
            """),
        ("Better Title.md", """
            ---
            name: Suggest a Better Title
            description: Three title ideas for the note
            icon: textformat
            show-in: [chat]
            uses-note: true
            order: 5
            ---
            Suggest three better titles for this note, each on its own line, with a few words on why.
            """),
    ]
}
