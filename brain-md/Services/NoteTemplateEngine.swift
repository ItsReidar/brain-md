//
//  NoteTemplateEngine.swift
//  brain-md
//

import Foundation

/// Engine for evaluating note titles and initial Markdown content templates based on presets and user-defined tokens.
public enum NoteTemplateEngine {
    
    // MARK: - Presets
    
    public enum TitleFormatPreset: String, CaseIterable, Identifiable, Sendable {
        case untitled = "untitled"
        case date = "date"
        case journal = "journal"
        case custom = "custom"
        
        public var id: String { rawValue }
        
        public var displayName: String {
            switch self {
            case .untitled: return "Untitled"
            case .date: return "Date (YYYY-MM-DD)"
            case .journal: return "Daily Journal"
            case .custom: return "Custom…"
            }
        }
    }
    
    public enum ContentTemplatePreset: String, CaseIterable, Identifiable, Sendable {
        case heading = "heading"
        case dateHeading = "dateheading"
        case journal = "journal"
        case meeting = "meeting"
        case blank = "blank"
        case custom = "custom"
        
        public var id: String { rawValue }
        
        public var displayName: String {
            switch self {
            case .heading: return "Heading Only"
            case .dateHeading: return "Date & Heading"
            case .journal: return "Daily Journal"
            case .meeting: return "Meeting Notes"
            case .blank: return "Blank"
            case .custom: return "Custom…"
            }
        }
        
        public var defaultTemplate: String {
            switch self {
            case .heading:
                return "# {{title}}\n\n"
            case .dateHeading:
                return "# {{title}}\n\n*Created: {{date}}*\n\n"
            case .journal:
                return """
                # {{title}}
                *{{date}}*
                
                ## Log
                - 
                
                ## Tasks
                - [ ] 
                
                ## Notes
                
                """
            case .meeting:
                return """
                # {{title}}
                **Date:** {{date}}
                **Attendees:** 
                
                ## Agenda
                1. 
                
                ## Discussion
                
                ## Action Items
                - [ ] 
                
                """
            case .blank:
                return ""
            case .custom:
                return "# {{title}}\n\n"
            }
        }
    }
    
    // MARK: - Title Resolution
    
    /// Resolves a note title given a preset or custom format string.
    public static func resolveTitle(
        preset: String,
        customFormat: String = "",
        date: Date = Date()
    ) -> String {
        let normalizedPreset = preset.lowercased().trimmingCharacters(in: .whitespaces)
        
        if normalizedPreset == TitleFormatPreset.date.rawValue || normalizedPreset == "date" {
            return formatDate(date, format: "yyyy-MM-dd")
        } else if normalizedPreset == TitleFormatPreset.journal.rawValue || normalizedPreset == "daily journal" {
            return "Journal \(formatDate(date, format: "yyyy-MM-dd"))"
        } else if normalizedPreset == TitleFormatPreset.custom.rawValue {
            let format = customFormat.trimmingCharacters(in: .whitespacesAndNewlines)
            if format.isEmpty {
                return "Untitled"
            }
            return evaluateTitleTokens(format: format, date: date)
        } else {
            // Default "untitled"
            return "Untitled"
        }
    }
    
    /// Resolves the title by reading preferences from `UserDefaults`.
    public static func resolveTitle(
        from defaults: UserDefaults = .standard,
        date: Date = Date()
    ) -> String {
        var preset = defaults.string(forKey: "note_title_format") ?? ""
        // Legacy migration check
        if preset.isEmpty {
            if let legacy = defaults.string(forKey: "default_note_template") {
                if legacy.localizedCaseInsensitiveContains("Date") {
                    preset = "date"
                } else if legacy.localizedCaseInsensitiveContains("Journal") {
                    preset = "journal"
                }
            }
        }
        if preset.isEmpty {
            preset = "untitled"
        }
        
        let customFormat = defaults.string(forKey: "note_title_custom_format") ?? "{date} Note"
        return resolveTitle(preset: preset, customFormat: customFormat, date: date)
    }
    
    // MARK: - Content Resolution
    
    /// Resolves the Markdown body given a preset or custom template string, interpolating dynamic tokens.
    public static func resolveContent(
        preset: String,
        customTemplate: String = "",
        title: String,
        date: Date = Date()
    ) -> String {
        let normalized = preset.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        let templatePreset = ContentTemplatePreset(rawValue: normalized)
            ?? ContentTemplatePreset.allCases.first { $0.rawValue.lowercased() == normalized }
            ?? .heading
        
        let rawTemplate: String
        if templatePreset == .custom {
            rawTemplate = customTemplate.isEmpty ? ContentTemplatePreset.heading.defaultTemplate : customTemplate
        } else {
            rawTemplate = templatePreset.defaultTemplate
        }
        
        return evaluateContentTokens(template: rawTemplate, title: title, date: date)
    }
    
    /// Resolves the Markdown body by reading preferences from `UserDefaults`.
    public static func resolveContent(
        for title: String,
        from defaults: UserDefaults = .standard,
        date: Date = Date()
    ) -> String {
        let preset = defaults.string(forKey: "note_content_template_preset") ?? "heading"
        let custom = defaults.string(forKey: "note_content_custom_template") ?? "# {{title}}\n\n"
        return resolveContent(preset: preset, customTemplate: custom, title: title, date: date)
    }
    
    // MARK: - Token Evaluators
    
    public static func evaluateTitleTokens(format: String, date: Date) -> String {
        var result = format
        let dateStr = formatDate(date, format: "yyyy-MM-dd")
        let timeStr = formatDate(date, format: "HH-mm")
        let yearStr = formatDate(date, format: "yyyy")
        let monthStr = formatDate(date, format: "MM")
        let dayStr = formatDate(date, format: "dd")
        
        // Single and double brace replacements
        result = result.replacingOccurrences(of: "{{date}}", with: dateStr)
        result = result.replacingOccurrences(of: "{date}", with: dateStr)
        result = result.replacingOccurrences(of: "{{time}}", with: timeStr)
        result = result.replacingOccurrences(of: "{time}", with: timeStr)
        result = result.replacingOccurrences(of: "{{year}}", with: yearStr)
        result = result.replacingOccurrences(of: "{year}", with: yearStr)
        result = result.replacingOccurrences(of: "{{month}}", with: monthStr)
        result = result.replacingOccurrences(of: "{month}", with: monthStr)
        result = result.replacingOccurrences(of: "{{day}}", with: dayStr)
        result = result.replacingOccurrences(of: "{day}", with: dayStr)
        
        // Clean characters illegal in macOS filenames (/ and :)
        result = result.replacingOccurrences(of: "/", with: "-")
        result = result.replacingOccurrences(of: ":", with: "-")
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Untitled" : clean
    }
    
    public static func evaluateContentTokens(template: String, title: String, date: Date) -> String {
        var result = template
        let dateStr = formatDate(date, format: "yyyy-MM-dd")
        let timeStr = formatDate(date, format: "HH:mm")
        let yearStr = formatDate(date, format: "yyyy")
        let monthStr = formatDate(date, format: "MM")
        let dayStr = formatDate(date, format: "dd")
        
        // Title replacements
        result = result.replacingOccurrences(of: "{{title}}", with: title)
        result = result.replacingOccurrences(of: "{title}", with: title)
        
        // Date & Time replacements
        result = result.replacingOccurrences(of: "{{date}}", with: dateStr)
        result = result.replacingOccurrences(of: "{date}", with: dateStr)
        result = result.replacingOccurrences(of: "{{time}}", with: timeStr)
        result = result.replacingOccurrences(of: "{time}", with: timeStr)
        result = result.replacingOccurrences(of: "{{year}}", with: yearStr)
        result = result.replacingOccurrences(of: "{year}", with: yearStr)
        result = result.replacingOccurrences(of: "{{month}}", with: monthStr)
        result = result.replacingOccurrences(of: "{month}", with: monthStr)
        result = result.replacingOccurrences(of: "{{day}}", with: dayStr)
        result = result.replacingOccurrences(of: "{day}", with: dayStr)
        
        return result
    }
    
    // MARK: - Date Formatting Helper
    
    public static func formatDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
