//
//  TranscriptWriter.swift
//  brain-md
//

import Foundation

/// Writes a meeting transcript into the note as paragraphs: consecutive lines from the same speaker
/// join one paragraph with one timestamp, and a new timestamp starts when someone else speaks, after
/// a long silence, or when a paragraph has run for a couple of minutes.
nonisolated struct TranscriptWriter {
    /// A pause longer than this starts a new paragraph, even for the same speaker.
    static let maxGap: Double = 30
    /// A monologue still gets a fresh timestamp this often.
    static let maxParagraph: Double = 120

    struct Paragraph: Equatable {
        var speakerLabel: String
        var start: Double
        var end: Double
        /// The paragraph exactly as written at the end of the note.
        var line: String
    }

    private(set) var current: Paragraph?

    /// Whether `segment` continues `paragraph`: same speaker, soon after, and not too long already.
    static func continues(_ paragraph: Paragraph?, with segment: TranscriptionSegment) -> Bool {
        guard let paragraph, paragraph.speakerLabel == segment.speakerLabel else { return false }
        return segment.timestamp - paragraph.end <= maxGap && segment.timestamp - paragraph.start <= maxParagraph
    }

    /// Adds a final segment at the end of `content`. It extends the last paragraph in place when the
    /// same person is still talking and that paragraph is still the note's last text; if anything
    /// was typed after it, the segment starts a new line instead, so nothing typed is overwritten.
    mutating func write(_ segment: TranscriptionSegment, into content: inout String) {
        let end = segment.timestamp + segment.duration
        if var paragraph = current, Self.continues(paragraph, with: segment), content.hasSuffix(paragraph.line) {
            content.removeLast(paragraph.line.count)
            paragraph.line += " " + segment.text
            paragraph.end = max(paragraph.end, end)
            content += paragraph.line
            current = paragraph
        } else {
            let line = MeetingRecorder.line(for: segment)
            content += "\n" + line
            current = Paragraph(speakerLabel: segment.speakerLabel, start: segment.timestamp, end: end, line: line)
        }
    }

    /// The same grouping for a finished transcript (meeting minutes): one segment per paragraph,
    /// keeping the first segment's speaker and timestamp.
    static func paragraphs(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        var result: [TranscriptionSegment] = []
        var current: Paragraph?
        for segment in segments where segment.isFinal {
            let end = segment.timestamp + segment.duration
            if continues(current, with: segment), var last = result.popLast() {
                last.text += " " + segment.text
                last.duration = max(last.timestamp + last.duration, end) - last.timestamp
                result.append(last)
                current = current.map { paragraph in
                    var extended = paragraph
                    extended.end = max(paragraph.end, end)
                    return extended
                }
            } else {
                result.append(segment)
                current = Paragraph(speakerLabel: segment.speakerLabel, start: segment.timestamp, end: end, line: "")
            }
        }
        return result
    }
}
