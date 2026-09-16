import Foundation
import XCTest
@testable import Transcription

final class TranscriptAttributionRangeTests: XCTestCase {
    private let grouper = TranscriptParagraphGrouper(configuration: .sentenceTurns)

    private func row(_ id: String, _ text: String, _ start: Int, speaker: String? = "speaker_1",
                     distance: Int? = nil, manual: Bool = false, timed: Bool = true,
                     overlap: Bool = false) -> TranscriptSegment {
        TranscriptSegment(id: id, speakerID: speaker, speakerLabel: speaker ?? "Unknown speaker",
            startMs: start, endMs: start + 100, text: text, overlap: overlap,
            timingQuality: timed ? .asrWord : .segmentOnly, speakerConfidence: 0.61,
            words: timed ? [TimedWord(text: text, startMs: start, endMs: start + 100)] : nil,
            attributionSource: manual ? .manual : nil,
            speakerInference: distance.map { .init(speakerID: "speaker_1", speakerLabel: "Speaker 1",
                evidence: .nearestInterval(distanceMs: $0), provenance: "fixture", diarizationHoleMs: 150,
                overlapMs: 12) }, unresolvedSpeakerEvidence: speaker == nil ? .noCoverage : nil)
    }

    func testNearestEvidenceChangesJoinWithoutPromotingCanonicalIdentity() throws {
        let sources = [row("a", "We", 0), row("b", "could", 110, speaker: nil, distance: 20),
                       row("c", "continue.", 220, speaker: nil, distance: 90)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(sources)
        let result = grouper.paragraphs(from: sources)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sourceSegmentIDs, ["a", "b", "c"])
        XCTAssertEqual(result[0].attributionRanges.map(\.source), sources)
        XCTAssertEqual(result[0].attributionRanges.map(\.wordRange), [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(result[0].attributionRanges.map { $0.source.speakerID }, ["speaker_1", nil, nil])
        XCTAssertTrue(result[0].containsInferredAttribution)
        XCTAssertTrue(result[0].needsReview)
        XCTAssertEqual(try encoder.encode(sources), snapshot)
        for range in result[0].attributionRanges {
            XCTAssertEqual(Array(result[0].words![range.wordRange!]), range.source.words!)
        }
    }

    func testSentenceTurnsRemainDistinctFromReadingParagraphs() {
        let sources = [row("a", "Done.", 0), row("b", "Next.", 110)]
        XCTAssertEqual(TranscriptParagraphGrouper().paragraphs(from: sources).count, 1)
        XCTAssertEqual(grouper.paragraphs(from: sources).count, 2)
        XCTAssertEqual(grouper.paragraphs(from: sources.reversed()), grouper.paragraphs(from: sources))
    }

    func testSpeakerUnknownOverlapAndPauseBoundariesSurvive() {
        let first = row("a", "Continue", 0)
        for next in [row("b", "proposal", 110, speaker: "speaker_2"),
                     row("b", "unclear", 110, speaker: nil),
                     row("b", "together", 110, overlap: true),
                     row("b", "later", 1100)] {
            XCTAssertEqual(grouper.paragraphs(from: [first, next]).count, 2)
        }
        let unknowns = [row("a", "Finished.", 0, speaker: nil), row("b", "Next", 110, speaker: nil)]
        XCTAssertEqual(grouper.paragraphs(from: unknowns).count, 2)
    }

    func testBackchannelHasSeparateIdentityWordsAndEvidence() {
        let sources = [row("a", "We", 0), row("b", "yeah", 110, speaker: "speaker_2"),
                       row("c", "continue", 220)]
        let result = grouper.paragraphs(from: sources)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].attributionRanges.map(\.source.id), ["a", "c"])
        XCTAssertEqual(result[0].attributionRanges.map(\.wordRange), [0..<1, 1..<2])
        XCTAssertEqual(result[0].asides[0].attributionRanges.map(\.source), [sources[1]])
        XCTAssertEqual(result[0].asides[0].speakerID, "speaker_2")
    }

    func testManualUnknownOverridesStaleSuggestionAndUntimedEditsHaveNoWordRange() {
        let manual = row("a", "edited text", 0, speaker: nil, distance: 20, manual: true, timed: false)
        let next = row("b", "fragment", 110, speaker: nil)
        let result = grouper.paragraphs(from: [manual, next])
        XCTAssertNil(result[0].speakerID)
        XCTAssertFalse(result[0].containsInferredAttribution)
        XCTAssertEqual(result[0].attributionRanges.map(\.source), [manual, next])
        XCTAssertEqual(result[0].attributionRanges.map(\.wordRange), [nil, 0..<1])
        XCTAssertEqual(result[0].timingQuality, .segmentOnly)
    }

    func testSplitRegroupAndUndoPreserveSourceIDsEvidenceAndCanonicalExports() throws {
        let source = TranscriptSegment(id: "source", speakerID: nil, speakerLabel: "Unknown speaker",
            startMs: 0, endMs: 500, text: "Maybe later", overlap: false, timingQuality: .asrWord,
            words: [.init(text: "Maybe", startMs: 0, endMs: 200), .init(text: "later", startMs: 250, endMs: 500)],
            speakerInference: .init(speakerID: "speaker_1", speakerLabel: "Speaker 1",
                evidence: .nearestInterval(distanceMs: 20), provenance: "fixture"))
        let transcript = CanonicalTranscript(transcriptID: "ranges", revision: 1, status: .complete,
            createdAt: "2026-09-16T00:00:00Z",
            source: .init(filename: "fixture.wav", durationMs: 1000, checksum: "sha256:fixture"),
            language: "en", languageSource: .detected,
            speakers: [.init(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")], segments: [source])
        let before = grouper.paragraphs(from: transcript.segments)
        let encoded = try CanonicalTranscriptCodec.encode(transcript)
        let split = try TranscriptSegmentEditor.splitting(segmentID: source.id, beforeToken: 1, in: transcript)
        let result = grouper.paragraphs(from: split.segments)
        XCTAssertEqual(result[0].sourceSegmentIDs, ["source.1", "source.2"])
        XCTAssertEqual(result[0].attributionRanges.map(\.source), split.segments)
        let undone = transcript.asRevision(split.revision + 1)
        XCTAssertEqual(grouper.paragraphs(from: undone.segments), before)
        XCTAssertEqual(try CanonicalTranscriptCodec.encode(transcript), encoded)
        XCTAssertEqual(grouper.paragraphs(from: try CanonicalTranscriptCodec.decode(encoded).segments), before)
        XCTAssertTrue(try TranscriptTextExporter.export(transcript).contains("Unknown speaker"))
        XCTAssertTrue(try TranscriptJSONExporter.export(transcript).contains("\"speaker_id\": null"))
    }
}
