//
//  TranscriptWriterTests.swift
//  brain-mdTests
//

import Foundation
import Testing
@testable import brain_md

struct TranscriptWriterTests {
    private let heading = "# Sync\n\n## Meeting transcript\n"

    private func segment(
        _ text: String, at timestamp: Double, duration: Double = 3,
        _ speaker: TranscriptionSegment.Speaker = .systemAudio, index: Int? = 0
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            speaker: speaker, speakerIndex: speaker == .microphone ? nil : index,
            timestamp: timestamp, duration: duration, text: text, isFinal: true)
    }

    private func write(_ segments: [TranscriptionSegment], into content: String? = nil) -> String {
        var writer = TranscriptWriter()
        var note = content ?? heading
        for segment in segments { writer.write(segment, into: &note) }
        return note
    }

    @Test func sameSpeakerJoinsOneParagraphWithOneTimestamp() {
        let note = write([
            segment("We slip two weeks.", at: 192),
            segment("Certification failed.", at: 196),
            segment("Marketing keeps the date.", at: 200),
        ])
        #expect(note == heading + "\n- **Speaker 1** [03:12] We slip two weeks. Certification failed. Marketing keeps the date.")
    }

    @Test func anotherSpeakerStartsANewLine() {
        let note = write([
            segment("We slip two weeks.", at: 192),
            segment("Agreed.", at: 196, .microphone),
            segment("Then we tell sales.", at: 199, .microphone),
            segment("I'll do that.", at: 203, index: 1),
            segment("And the FAQ.", at: 206, index: 0),
        ])
        #expect(note == heading + """

            - **Speaker 1** [03:12] We slip two weeks.
            - **Me** [03:16] Agreed. Then we tell sales.
            - **Speaker 2** [03:23] I'll do that.
            - **Speaker 1** [03:26] And the FAQ.
            """)
    }

    @Test func callAudioWithoutSpeakerIdentificationGroupsAsThem() {
        let note = write([segment("One.", at: 0, index: nil), segment("Two.", at: 4, index: nil)])
        #expect(note == heading + "\n- **Them** [00:00] One. Two.")
    }

    @Test func aLongPauseStartsANewTimestamp() {
        // The first paragraph ends at 3 s; 34 s is more than 30 s later.
        let note = write([segment("Before the break.", at: 0), segment("After it.", at: 34)])
        #expect(note == heading + "\n- **Speaker 1** [00:00] Before the break.\n- **Speaker 1** [00:34] After it.")
        let short = write([segment("Before.", at: 0), segment("After.", at: 32)])
        #expect(short == heading + "\n- **Speaker 1** [00:00] Before. After.")
    }

    @Test func aMonologueGetsAFreshTimestampEveryTwoMinutes() {
        let segments = stride(from: 0.0, through: 150, by: 10).map { segment("Line \(Int($0)).", at: $0, duration: 9) }
        let lines = write(segments).split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("- **Speaker 1** [00:00] Line 0. Line 10."))
        #expect(lines[0].hasSuffix("Line 120."))
        #expect(lines[1] == "- **Speaker 1** [02:10] Line 130. Line 140. Line 150.")
    }

    @Test func textTypedAfterTheParagraphIsNeverOverwritten() {
        var writer = TranscriptWriter()
        var note = heading
        writer.write(segment("We slip two weeks.", at: 0), into: &note)
        note += "\nMy own note."
        writer.write(segment("Certification failed.", at: 4), into: &note)
        writer.write(segment("Marketing keeps the date.", at: 8), into: &note)
        #expect(note == heading + """

            - **Speaker 1** [00:00] We slip two weeks.
            My own note.
            - **Speaker 1** [00:04] Certification failed. Marketing keeps the date.
            """)
    }

    @Test func editsEarlierInTheNoteDontBreakTheParagraph() {
        var writer = TranscriptWriter()
        var note = heading
        writer.write(segment("We slip two weeks.", at: 0), into: &note)
        note = note.replacingOccurrences(of: "# Sync", with: "# Launch sync")
        writer.write(segment("Certification failed.", at: 4), into: &note)
        #expect(note == "# Launch sync\n\n## Meeting transcript\n\n- **Speaker 1** [00:00] We slip two weeks. Certification failed.")
    }

    @Test func outOfOrderSegmentsFromOneSpeakerStillJoin() {
        // The other source's pipeline can finish an earlier utterance a little later.
        let note = write([segment("Second.", at: 10), segment("First.", at: 6)])
        #expect(note == heading + "\n- **Speaker 1** [00:10] Second. First.")
    }

    @Test func minutesUseTheSameParagraphs() throws {
        let segments = [
            segment("We slip two weeks.", at: 0), segment("Certification failed.", at: 4),
            TranscriptionSegment(speaker: .microphone, timestamp: 6, text: "partial", isFinal: false),
            segment("Agreed.", at: 8, .microphone),
        ]
        let paragraphs = TranscriptWriter.paragraphs(segments)
        #expect(paragraphs.map(\.text) == ["We slip two weeks. Certification failed.", "Agreed."])
        #expect(paragraphs[0].timestamp == 0 && paragraphs[0].duration == 7)

        let prompt = try LanguageModelService.prompt(
            for: RewriteRequest(mode: .summarizeMeeting, transcripts: segments))
        #expect(prompt.contains("Speaker 1: We slip two weeks. Certification failed.\nMe: Agreed."))
    }
}
