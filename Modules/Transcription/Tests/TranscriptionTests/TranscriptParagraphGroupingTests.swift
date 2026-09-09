import Foundation
import XCTest
@testable import Transcription

/// Presentation paragraphs are derived from canonical segments. They must not
/// rewrite speaker assignments, words, timestamps, or manual edits.
final class TranscriptParagraphGroupingTests: XCTestCase {
    func testConsecutiveSameSpeakerSegmentsGroupIntoOneParagraph() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "That's fine.", words: [
                TimedWord(text: "That's", startMs: 0, endMs: 200),
                TimedWord(text: "fine.", startMs: 220, endMs: 400),
            ]),
            segment("b", speaker: "speaker_1", start: 450, end: 1_000, text: "We can wait.", words: [
                TimedWord(text: "We", startMs: 450, endMs: 600),
                TimedWord(text: "can", startMs: 620, endMs: 780),
                TimedWord(text: "wait.", startMs: 800, endMs: 1_000),
            ]),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].speakerID, "speaker_1")
        XCTAssertEqual(paragraphs[0].text, "That's fine. We can wait.")
        XCTAssertEqual(paragraphs[0].startMs, 0)
        XCTAssertEqual(paragraphs[0].endMs, 1_000)
        XCTAssertEqual(paragraphs[0].sourceSegmentIDs, ["a", "b"])
        XCTAssertEqual(paragraphs[0].words, segments.flatMap { $0.words ?? [] })
        XCTAssertEqual(segments.map(\.text), ["That's fine.", "We can wait."], "canonical segments stay as they were")
    }

    func testUnknownSentenceBoundaryDoesNotTreatAllUnknownsAsOneSpeaker() {
        let segments = [
            segment("a", speaker: nil, start: 0, end: 200, text: "Hello."),
            segment("b", speaker: nil, start: 250, end: 600, text: "Hey, hey."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), [nil, nil])
        XCTAssertEqual(paragraphs.map(\.text), ["Hello.", "Hey, hey."])
        XCTAssertEqual(paragraphs.map(\.sourceSegmentIDs), [["a"], ["b"]])
    }

    func testContiguousUnknownFragmentsMayGroupUntilASentenceBoundary() {
        let segments = [
            segment("a", speaker: nil, start: 0, end: 200, text: "Maybe"),
            segment("b", speaker: nil, start: 220, end: 400, text: "later."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertNil(paragraphs[0].speakerID)
        XCTAssertEqual(paragraphs[0].text, "Maybe later.")
        XCTAssertEqual(paragraphs[0].sourceSegmentIDs, ["a", "b"])
    }

    func testSpeakerChangeAndShortAcknowledgmentStaySeparate() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "So"),
            segment("b", speaker: "speaker_2", start: 250, end: 500, text: "Mm-hm."),
            segment("c", speaker: "speaker_1", start: 550, end: 900, text: "anyway."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_1"])
        XCTAssertEqual(paragraphs.map(\.text), ["So", "Mm-hm.", "anyway."])
        XCTAssertEqual(paragraphs.map(\.sourceSegmentIDs), [["a"], ["b"], ["c"]])
    }

    func testKnownSpeakerDoesNotAbsorbAnUnknownSpan() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello."),
            segment("b", speaker: nil, start: 250, end: 500, text: "unclear"),
            segment("c", speaker: "speaker_1", start: 550, end: 800, text: "there."),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1", nil, "speaker_1"])
        XCTAssertEqual(paragraphs.map(\.text), ["Hello.", "unclear", "there."])
    }

    func testOverlapIndicatorIsPreservedOnTheParagraph() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "Alpha", overlap: false),
            segment("b", speaker: "speaker_2", start: 300, end: 900, text: "Bravo", overlap: true),
        ]

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)

        XCTAssertEqual(paragraphs.map(\.speakerID), ["speaker_1", "speaker_2"])
        XCTAssertEqual(paragraphs.map(\.overlap), [false, true])
    }

    func testPauseAndPreferredLimitsStillSplitSameSpeakerSpeech() {
        let pauseSplit = [
            segment("a", speaker: "speaker_1", start: 0, end: 400, text: "Hello."),
            segment("b", speaker: "speaker_1", start: 1_500, end: 1_800, text: "Later."),
        ]
        XCTAssertEqual(TranscriptParagraphGrouper().paragraphs(from: pauseSplit).map(\.text), ["Hello.", "Later."])

        let grouping = TranscriptDisplayGrouper.Configuration(
            preferredSegmentDurationMs: 1_000,
            preferredWordCount: 4,
            maximumSegmentDurationMs: 30_000,
            maximumWordCount: 80
        )
        let preferred = [
            segment("a", speaker: "speaker_1", start: 0, end: 1_100, text: "One. Two. Three. Four.", words: [
                TimedWord(text: "One.", startMs: 0, endMs: 200),
                TimedWord(text: "Two.", startMs: 250, endMs: 500),
                TimedWord(text: "Three.", startMs: 550, endMs: 800),
                TimedWord(text: "Four.", startMs: 850, endMs: 1_100),
            ]),
            segment("b", speaker: "speaker_1", start: 1_150, end: 1_400, text: "Five.", words: [
                TimedWord(text: "Five.", startMs: 1_150, endMs: 1_400),
            ]),
        ]
        XCTAssertEqual(
            TranscriptParagraphGrouper(configuration: grouping).paragraphs(from: preferred).map(\.text),
            ["One. Two. Three. Four.", "Five."]
        )
    }

    func testGroupingDoesNotRewriteCanonicalAttributionOrWordTimings() {
        let original = [
            segment("a", speaker: "speaker_1", start: 100, end: 250, text: "Hello.", words: [
                TimedWord(text: "Hello.", startMs: 100, endMs: 250),
            ]),
            segment("b", speaker: "speaker_1", start: 300, end: 500, text: "There.", words: [
                TimedWord(text: "There.", startMs: 300, endMs: 500),
            ]),
        ]
        let snapshot = original.map(CanonicalSnapshot.init)

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: original)

        XCTAssertEqual(original.map(CanonicalSnapshot.init), snapshot)
        XCTAssertEqual(paragraphs[0].words, [
            TimedWord(text: "Hello.", startMs: 100, endMs: 250),
            TimedWord(text: "There.", startMs: 300, endMs: 500),
        ])
        XCTAssertEqual(paragraphs.flatMap(\.sourceSegmentIDs), original.map(\.id))
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " "), original.map(\.text).joined(separator: " "))
    }

    func testReferenceRunParagraphsPreserveOrderCompletenessAndAttribution() throws {
        let url = URL(
            fileURLWithPath: "/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12/canonical-transcript.json"
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Reference run is not on this machine")

        let transcript = try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
        let original = transcript.segments
        let snapshot = original.map(CanonicalSnapshot.init)

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: original)

        XCTAssertEqual(original.map(CanonicalSnapshot.init), snapshot)
        XCTAssertEqual(paragraphs.flatMap(\.sourceSegmentIDs), original.map(\.id))
        XCTAssertEqual(
            paragraphs.map(\.text).joined(separator: " "),
            original.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        )
        XCTAssertEqual(
            paragraphs.flatMap { $0.words ?? [] },
            original.flatMap { $0.words ?? [] }
        )

        let unknownParagraphs = paragraphs.filter { $0.speakerID == nil }
        XCTAssertGreaterThan(unknownParagraphs.count, 1, "unknown spans must stay unresolved rather than collapsing into one speaker")
        let overlapSourceIDs = Set(original.filter(\.overlap).map(\.id))
        let overlapParagraphSourceIDs = Set(paragraphs.filter(\.overlap).flatMap(\.sourceSegmentIDs))
        XCTAssertTrue(overlapSourceIDs.isSubset(of: overlapParagraphSourceIDs), "overlap indicators must remain visible in Paragraphs view")

        let speakerChanges = zip(original, original.dropFirst()).filter { $0.speakerID != $1.speakerID }.count
        let paragraphSpeakerChanges = zip(paragraphs, paragraphs.dropFirst()).filter { $0.speakerID != $1.speakerID }.count
        XCTAssertEqual(paragraphSpeakerChanges, speakerChanges)

        let grouped = paragraphs.filter { $0.sourceSegmentCount > 1 }.count
        let unknownWords = original.filter { $0.speakerID == nil }.flatMap { $0.words ?? [] }.count
        let adjacentSameKnown = zip(paragraphs, paragraphs.dropFirst()).filter {
            $0.speakerID != nil && $0.speakerID == $1.speakerID
        }.count
        let adjacentUnknown = zip(paragraphs, paragraphs.dropFirst()).filter {
            $0.speakerID == nil && $1.speakerID == nil
        }.count

        let aroundContraction = paragraphs.filter { $0.startMs >= 97_000 && $0.startMs <= 103_000 }
        XCTAssertFalse(aroundContraction.isEmpty, "the split contraction near 01:38 should remain visible")
        XCTAssertTrue(
            aroundContraction.contains { $0.speakerID == nil && $0.text.contains("ll") },
            "the unknown half of the split contraction must stay an unresolved span"
        )

        XCTAssertEqual(original.count, 1_033)
        XCTAssertEqual(paragraphs.count, 1_033, "existing grouping limits are a 1:1 baseline on this already-grouped run")
        XCTAssertEqual(grouped, 0)
        XCTAssertEqual(unknownParagraphs.count, 548)
        XCTAssertEqual(unknownWords, 814)
        XCTAssertEqual(adjacentSameKnown, 70)
        XCTAssertEqual(adjacentUnknown, 153)
        XCTAssertEqual(transcript.revision, 3)
    }

    private func segment(
        _ id: String,
        speaker: String?,
        start: Int,
        end: Int,
        text: String,
        overlap: Bool = false,
        words: [TimedWord]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerID: speaker,
            speakerLabel: speaker == nil ? "Unknown speaker" : "Speaker \(speaker!.suffix(1))",
            startMs: start,
            endMs: end,
            text: text,
            overlap: overlap,
            timingQuality: .asrWord,
            words: words ?? text.split(whereSeparator: \.isWhitespace).enumerated().map { index, token in
                let width = max(1, (end - start) / max(1, text.split(whereSeparator: \.isWhitespace).count))
                let tokenStart = start + index * width
                return TimedWord(text: String(token), startMs: tokenStart, endMs: min(end, tokenStart + width))
            }
        )
    }
}

private struct CanonicalSnapshot: Equatable {
    let id: String
    let speakerID: String?
    let speakerLabel: String
    let startMs: Int
    let endMs: Int
    let text: String
    let overlap: Bool
    let timingQuality: TranscriptTimingQuality
    let speakerConfidence: Double?
    let words: [TimedWord]?

    init(_ segment: TranscriptSegment) {
        id = segment.id
        speakerID = segment.speakerID
        speakerLabel = segment.speakerLabel
        startMs = segment.startMs
        endMs = segment.endMs
        text = segment.text
        overlap = segment.overlap
        timingQuality = segment.timingQuality
        speakerConfidence = segment.speakerConfidence
        words = segment.words
    }
}
