import Foundation
import XCTest
@testable import Transcription

/// Display-paragraph grouping is independent of speaker attribution and of subtitle
/// cue generation. These cases pin the investigation's grouping rules in
/// `docs/investigations/diarization-979.md` without requiring MacWhisper's
/// undocumented block algorithm.
final class TranscriptDisplayGroupingTests: XCTestCase {
    private let builder = SpeakerTurnBuilder()

    // MARK: - Same-speaker sentences

    func testConsecutiveSameSpeakerSentencesGroupIntoOneParagraph() throws {
        let result = try builder.build(
            words: [
                word("w1", "That's", 0, 200),
                word("w2", "fine.", 220, 400),
                word("w3", "We", 450, 600),
                word("w4", "can", 620, 780),
                word("w5", "wait.", 800, 1_000),
            ],
            diarizedTurns: [turn("A", 0, 1_200)]
        )

        XCTAssertEqual(result.segments.map(\.text), ["That's fine. We can wait."])
        XCTAssertEqual(result.segments.map(\.startMs), [0])
        XCTAssertEqual(result.segments.map(\.endMs), [1_000])
        XCTAssertEqual(result.wordAssignments.map(\.segmentID), Array(repeating: "segment_001", count: 5))
    }

    func testPunctuationIsOnlyAPreferredBreakAfterTheSoftLimits() throws {
        let grouping = TranscriptDisplayGrouper.Configuration(
            preferredSegmentDurationMs: 1_000,
            preferredWordCount: 4,
            maximumSegmentDurationMs: 30_000,
            maximumWordCount: 80
        )
        let result = try SpeakerTurnBuilder(configuration: .init(grouping: grouping)).build(
            words: [
                word("a", "One.", 0, 200),
                word("b", "Two.", 250, 500),
                word("c", "Three.", 550, 800),
                word("d", "Four.", 850, 1_100),
                word("e", "Five.", 1_150, 1_400),
            ],
            diarizedTurns: [turn("A", 0, 1_500)]
        )

        // Four words / 1.1 s reach both soft limits on "Four.", so "Five." starts a new row.
        XCTAssertEqual(result.segments.map(\.text), ["One. Two. Three. Four.", "Five."])
        XCTAssertEqual(result.segments.map(\.startMs), [0, 1_150])
    }

    func testHardDurationCapStillSplitsMidSentenceAtAWordBoundary() throws {
        let words = (0..<31).map { index in word("w\(index)", "word\(index)", index * 1_000, index * 1_000 + 500) }
        let result = try builder.build(words: words, diarizedTurns: [turn("A", 0, 31_000)])

        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map(\.startMs), [0, 30_000])
        XCTAssertEqual(result.segments.map(\.endMs), [29_500, 30_500])
        XCTAssertFalse(TranscriptDisplayGrouper().endsSentence("word30"))
    }

    func testHardWordCapSplitsUnpunctuatedSpeech() throws {
        let grouping = TranscriptDisplayGrouper.Configuration(preferredWordCount: 3, maximumWordCount: 3)
        let result = try SpeakerTurnBuilder(configuration: .init(grouping: grouping)).build(
            words: [
                word("a", "one", 0, 100),
                word("b", "two", 120, 220),
                word("c", "three", 240, 340),
                word("d", "four", 360, 460),
            ],
            diarizedTurns: [turn("A", 0, 500)]
        )

        XCTAssertEqual(result.segments.map(\.text), ["one two three", "four"])
    }

    // MARK: - Speaker changes, acknowledgments, unknown, overlap

    func testShortAcknowledgmentFromAnotherSpeakerStaysItsOwnRow() throws {
        let result = try builder.build(
            words: [
                word("a", "So", 0, 200),
                word("b", "Mm-hm.", 250, 500),
                word("c", "anyway.", 550, 900),
            ],
            diarizedTurns: [turn("A", 0, 220), turn("B", 240, 520), turn("A", 540, 1_000)]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_1"])
        XCTAssertEqual(result.segments.map(\.text), ["So", "Mm-hm.", "anyway."])
    }

    func testKnownSpeakerDoesNotAbsorbAnUnknownSpan() throws {
        let result = try builder.build(
            words: [
                word("a", "Hello.", 0, 200),
                word("b", "unclear", 250, 500),
                word("c", "there.", 550, 800),
            ],
            diarizedTurns: [turn("A", 0, 220), turn("A", 540, 900)]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", nil, "speaker_1"])
        XCTAssertEqual(result.segments.map(\.text), ["Hello.", "unclear", "there."])
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker 1", "Unknown speaker", "Speaker 1"])
    }

    func testContiguousUnknownWordsGroupButStayUnknown() throws {
        let result = try builder.build(
            words: [
                word("a", "Maybe", 0, 200),
                word("b", "later.", 220, 400),
            ],
            diarizedTurns: []
        )

        XCTAssertEqual(result.segments.count, 1)
        XCTAssertNil(result.segments[0].speakerID)
        XCTAssertEqual(result.segments[0].text, "Maybe later.")
        XCTAssertEqual(result.wordAssignments.map(\.speakerID), [nil, nil])
    }

    func testUnknownSentenceBoundaryDoesNotMergeWithoutIdentityEvidence() throws {
        let result = try builder.build(
            words: [
                word("a", "Hello.", 0, 200),
                word("b", "Hey,", 250, 400),
                word("c", "hey.", 420, 600),
            ],
            diarizedTurns: []
        )

        XCTAssertEqual(result.segments.map(\.speakerID), [nil, nil])
        XCTAssertEqual(result.segments.map(\.text), ["Hello.", "Hey, hey."])
    }

    func testOverlappingSpeechKeepsBothSpeakersAndTheOverlapFlag() throws {
        let result = try builder.build(
            words: [
                word("a", "Alpha", 0, 400),
                word("b", "Bravo", 500, 900),
            ],
            diarizedTurns: [turn("A", 0, 550), turn("B", 450, 1_000)]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2"])
        XCTAssertEqual(result.segments.map(\.text), ["Alpha", "Bravo"])
        XCTAssertFalse(result.segments[0].overlap)
        XCTAssertTrue(result.segments[1].overlap)
    }

    func testGroupedParagraphsRemainStructurallyEditable() throws {
        let result = try builder.build(
            words: [
                word("w1", "That's", 0, 200),
                word("w2", "fine.", 220, 400),
                word("w3", "We", 450, 600),
                word("w4", "can", 620, 780),
                word("w5", "wait.", 800, 1_000),
            ],
            diarizedTurns: [turn("A", 0, 1_200)]
        )
        let transcript = makeTranscript(from: result, durationMs: 2_000)
        XCTAssertEqual(TranscriptSegmentEditor.splitTokens(for: result.segments[0]).count, 5)

        let split = try TranscriptSegmentEditor.splitting(segmentID: "segment_001", beforeToken: 2, in: transcript)
        XCTAssertEqual(split.segments.map(\.text), ["That's fine.", "We can wait."])
        XCTAssertEqual(split.subtitleCueMappings, nil)

        let merged = try TranscriptSegmentEditor.merging(segmentID: split.segments[0].id, with: split.segments[1].id, in: split)
        XCTAssertEqual(merged.segments.map(\.text), ["That's fine. We can wait."])
        XCTAssertEqual(merged.segments[0].speakerID, "speaker_1")
    }

    func testWordTimingsSurviveGrouping() throws {
        let result = try builder.build(
            words: [
                word("a", "Hello.", 100, 250),
                word("b", "There.", 300, 500),
            ],
            diarizedTurns: [turn("A", 0, 600)]
        )

        XCTAssertEqual(result.segments[0].timingQuality, .asrWord)
        XCTAssertEqual(
            result.segments[0].words,
            [TimedWord(text: "Hello.", startMs: 100, endMs: 250), TimedWord(text: "There.", startMs: 300, endMs: 500)]
        )
    }

    // MARK: - Export: transcript paragraphs vs subtitle cues

    func testGroupedParagraphsExportAsReadableTextAndIndependentSubtitleCues() throws {
        let words: [RecognizedWord] = [
            word("w01", "Today", 2_000, 2_300),
            word("w02", "we", 2_350, 2_500),
            word("w03", "review", 2_550, 2_900),
            word("w04", "the", 2_950, 3_100),
            word("w05", "plan.", 3_150, 3_500),
            word("w06", "Please", 3_600, 3_900),
            word("w07", "follow", 3_950, 4_300),
            word("w08", "along", 4_350, 4_700),
            word("w09", "closely.", 4_750, 5_200),
            word("w10", "Nothing", 5_300, 5_600),
            word("w11", "here", 5_650, 5_900),
            word("w12", "should", 5_950, 6_300),
            word("w13", "be", 6_350, 6_500),
            word("w14", "missed.", 6_550, 7_000),
            word("ack", "Yes.", 7_200, 7_500),
            word("w15", "We", 7_700, 7_900),
            word("w16", "continue", 7_950, 8_400),
            word("w17", "after", 8_450, 8_700),
            word("w18", "that.", 8_750, 9_200),
        ]
        let result = try builder.build(
            words: words,
            diarizedTurns: [turn("A", 1_900, 7_050), turn("B", 7_150, 7_600), turn("A", 7_650, 9_400)]
        )

        XCTAssertEqual(result.segments.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_1"])
        XCTAssertEqual(result.segments.map(\.text), [
            "Today we review the plan. Please follow along closely. Nothing here should be missed.",
            "Yes.",
            "We continue after that.",
        ])

        let transcript = makeTranscript(from: result, durationMs: 12_000)
        try CanonicalTranscriptValidator.validate(transcript)

        let text = try TranscriptExporter.plainText(transcript)
        XCTAssertEqual(text, """
        [00:00:02.000 --> 00:00:07.000] Speaker 1: Today we review the plan. Please follow along closely. Nothing here should be missed.

        [00:00:07.200 --> 00:00:07.500] Speaker 2: Yes.

        [00:00:07.700 --> 00:00:09.200] Speaker 1: We continue after that.

        """)

        let cues = try SubtitleCueBuilder.cues(for: transcript)
        XCTAssertGreaterThan(cues.count, 1, "subtitle cues still split a long display paragraph")
        XCTAssertEqual(cues.flatMap { $0.blocks.map(\.text) }.joined(separator: " "), result.segments.map(\.text).joined(separator: " "))
        XCTAssertEqual(cues.first?.startMs, 2_000)
        XCTAssertEqual(cues.last?.endMs, 9_200)
        XCTAssertEqual(Set(cues.flatMap(\.parentSegmentIDs)), Set(result.segments.map(\.id)))

        let srt = try TranscriptExporter.srt(transcript)
        XCTAssertTrue(srt.contains("Speaker 1: Today we review"))
        XCTAssertTrue(srt.contains("Speaker 2: Yes."))
        XCTAssertFalse(srt.contains("[overlap]"))
        XCTAssertGreaterThanOrEqual(srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count, 3)
    }

    func testInvalidGroupingConfigurationIsRejected() {
        let invalid = TranscriptDisplayGrouper.Configuration(
            preferredSegmentDurationMs: 40_000,
            maximumSegmentDurationMs: 30_000
        )
        XCTAssertFalse(TranscriptDisplayGrouper(configuration: invalid).isValid)
        XCTAssertThrowsError(
            try SpeakerTurnBuilder(configuration: .init(grouping: invalid)).build(words: [], diarizedTurns: [])
        ) { error in
            XCTAssertEqual(error as? SpeakerTurnBuilder.Error, .invalidConfiguration)
        }
    }

    // MARK: - Helpers

    private func word(_ id: String, _ text: String, _ startMs: Int, _ endMs: Int) -> RecognizedWord {
        RecognizedWord(id: id, text: text, startMs: startMs, endMs: endMs, enclosingStartMs: startMs, enclosingEndMs: endMs)
    }

    private func turn(_ speakerID: String, _ startMs: Int, _ endMs: Int) -> DiarizedSpeakerTurn {
        DiarizedSpeakerTurn(speakerID: speakerID, startMs: startMs, endMs: endMs)
    }

    private func makeTranscript(from result: SpeakerTurnBuildResult, durationMs: Int) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "grouping-export",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-08T21:00:00Z",
            source: TranscriptSource(filename: "grouping.flac", durationMs: durationMs, checksum: "sha256:grouping"),
            language: "en",
            languageSource: .detected,
            speakers: result.speakers,
            segments: result.segments
        )
    }
}
