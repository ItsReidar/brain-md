//
//  PreviewProvider.swift
//  brain-md-QuickLook
//
//  Finder's Quick Look preview (Space) for Markdown files, rendered like Brain.md's preview.
//

import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "itsreidar.brain-md.QuickLook", category: "Preview")

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    nonisolated func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        // Markdown is almost always UTF-8; decode leniently rather than show nothing.
        let markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let preview = MarkdownQuickLook.render(markdown: markdown, fileURL: request.fileURL)

        // Images next to the note, when the sandbox lets the extension read them; the rest show
        // their alt text.
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        for (key, url) in preview.images {
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments[key] = QLPreviewReplyAttachment(
                data: data, contentType: UTType(filenameExtension: url.pathExtension) ?? .image)
        }
        let html = preview.html(withoutImages: Set(preview.images.keys).subtracting(attachments.keys))
        log.info("Rendered \(html.utf8.count, privacy: .public) bytes of HTML, \(attachments.count, privacy: .public) of \(preview.images.count, privacy: .public) images attached")

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = attachments
            return Data(html.utf8)
        }
    }
}
