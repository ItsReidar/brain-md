//
//  NoteItem.swift
//  brain-md
//

import Foundation

public struct NoteItem: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let name: String
    public let relativePath: String
    public let url: URL
    public let isDirectory: Bool
    public var children: [NoteItem]?
    public let modifiedAt: Date
    public let size: Int64
    public var tags: [String]
    /// A Markdown file opened from Finder that lives outside the vault. `relativePath` is then its
    /// absolute path, and it's saved straight to `url`.
    public var isExternal = false
    
    public init(
        name: String,
        relativePath: String,
        url: URL,
        isDirectory: Bool,
        children: [NoteItem]? = nil,
        modifiedAt: Date = Date(),
        size: Int64 = 0,
        tags: [String] = []
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.modifiedAt = modifiedAt
        self.size = size
        self.tags = tags
    }
    
    /// Extensions of the Markdown type (`net.daringfireball.markdown`) brain-md opens from Finder.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "tiff", "tif", "bmp", "heic", "ico"
    ]
    
    public var isMarkdown: Bool {
        guard !isDirectory else { return false }
        let ext = url.pathExtension.lowercased()
        return Self.markdownExtensions.contains(ext) || ext == "txt"
    }
    
    public var isImage: Bool {
        guard !isDirectory else { return false }
        let ext = url.pathExtension.lowercased()
        return Self.supportedImageExtensions.contains(ext)
    }
    
    public var isAttachment: Bool {
        guard !isDirectory else { return false }
        return !isMarkdown
    }
    
    public var displayName: String {
        if isDirectory {
            return name
        }
        if isMarkdown && name.lowercased().hasSuffix(".md") {
            return String(name.dropLast(3))
        }
        return name
    }
    
    public var iconName: String {
        if isDirectory {
            return "folder.fill"
        }
        if isImage {
            return "photo.fill"
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return "doc.richtext.fill"
        }
        if isMarkdown {
            return "doc.text.fill"
        }
        return "paperclip"
    }
    
    public var formattedSize: String {
        guard !isDirectory else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
    
    public var formattedModifiedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: modifiedAt)
    }
}

public struct ActivityLog: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: String
    public let detail: String
    public let isError: Bool
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        action: String,
        detail: String,
        isError: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.detail = detail
        self.isError = isError
    }
}

public struct NoteSearchResult: Identifiable, Sendable, Equatable {
    public var id: String { relativePath }
    public let relativePath: String
    public let title: String
    public let snippet: String
    public let matchLine: Int?
    
    public init(
        relativePath: String,
        title: String,
        snippet: String,
        matchLine: Int? = nil
    ) {
        self.relativePath = relativePath
        self.title = title
        self.snippet = snippet
        self.matchLine = matchLine
    }
}
