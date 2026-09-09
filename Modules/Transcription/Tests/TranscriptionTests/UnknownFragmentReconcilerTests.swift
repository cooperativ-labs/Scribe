import Foundation
import XCTest
@testable import Transcription

final class UnknownFragmentReconcilerTests: XCTestCase {
    private let speakers = [
        TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1"),
        TranscriptSpeaker(id: "speaker_2", identityAssignment: .unmatched, labelSnapshot: "Speaker 2"),
    ]

    func testBoundaryGapInfersWhenDiarizationHoleIsShortAndUnoccupied() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "there"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "friend."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertEqual(result.map(\.speakerID), ["speaker_1", nil, "speaker_1"], "original attribution is preserved")
        XCTAssertEqual(result[1].speakerInference?.speakerID, "speaker_1")
        XCTAssertEqual(result[1].speakerInference?.evidence, .diarizationBoundaryGap)
        XCTAssertEqual(result[1].speakerInference?.provenance, UnknownFragmentReconciler.provenance)
        XCTAssertEqual(result[1].speakerInference?.diarizationHoleMs, 210)
        XCTAssertEqual(result[1].attributionSource, .inferred)
        XCTAssertEqual(result[1].effectiveSpeakerID, "speaker_1")
        XCTAssertTrue(result[1].hasInferredSpeaker)
        XCTAssertEqual(result.map(\.text), segments.map(\.text))
        XCTAssertEqual(result.map(\.startMs), segments.map(\.startMs))
    }

    func testNeighborsAloneWithoutADiarizationHoleDoNotEstablishIdentity() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "maybe"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "later."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 10_000, 10_800),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertNil(result[1].speakerInference)
        XCTAssertEqual(result[1].unresolvedSpeakerEvidence, .noCoverage)
        XCTAssertNil(result[1].effectiveSpeakerID)
    }

    func testLinguisticContinuityWithoutDiarizationDoesNotAssign() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "you'"),
            segment("b", speaker: nil, start: 220, end: 400, text: "ll"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "see."),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: []
        )

        XCTAssertNil(result[1].speakerInference)
        XCTAssertEqual(result[1].unresolvedSpeakerEvidence, .noCoverage)
    }

    func testInsufficientOverlapStaysUnresolvedEvenInASandwich() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "you'"),
            segment("b", speaker: nil, start: 250, end: 570, text: "ll"),
            segment("c", speaker: "speaker_1", start: 600, end: 900, text: "see."),
        ]
        let intervals = [
            interval("speaker_1", 0, 300),
            interval("speaker_1", 580, 920),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertNil(result[1].speakerInference)
        XCTAssertEqual(result[1].unresolvedSpeakerEvidence, .insufficientOverlap)
        XCTAssertEqual(result[1].speakerID, nil)
    }

    func testCompetingSpeakerAndOverlapStayUnresolved() {
        let sandwich = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "wait", overlap: false),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "there."),
        ]
        let competing = [
            interval("speaker_1", 0, 220),
            interval("speaker_2", 240, 420),
            interval("speaker_1", 430, 820),
        ]
        let competingResult = UnknownFragmentReconciler().reconcile(
            segments: sandwich,
            speakers: speakers,
            intervals: competing
        )
        XCTAssertNil(competingResult[1].speakerInference)
        XCTAssertEqual(competingResult[1].unresolvedSpeakerEvidence, .competingSpeakers)

        let overlapped = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "hey", overlap: true),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "there."),
        ]
        let hole = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]
        let overlapResult = UnknownFragmentReconciler().reconcile(
            segments: overlapped,
            speakers: speakers,
            intervals: hole
        )
        XCTAssertNil(overlapResult[1].speakerInference)
        XCTAssertTrue(overlapResult[1].overlap)
    }

    func testSpeakerChangeDoesNotInfer() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "Okay."),
            segment("c", speaker: "speaker_2", start: 450, end: 800, text: "Sure."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 500),
            interval("speaker_2", 450, 820),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertNil(result[1].speakerInference)
        XCTAssertNil(result[1].effectiveSpeakerID)
    }

    func testManualUnknownIsNotOverwritten() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "there", attributionSource: .manual),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "friend."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertNil(result[1].speakerInference)
        XCTAssertEqual(result[1].attributionSource, .manual)
    }

    func testUniqueCoverageMatchingNeighborsCanInfer() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 220, end: 400, text: "there"),
            segment("c", speaker: "speaker_1", start: 420, end: 800, text: "friend."),
        ]
        let intervals = [interval("speaker_1", 0, 820)]

        let result = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )

        XCTAssertEqual(result[1].speakerInference?.speakerID, "speaker_1")
        XCTAssertEqual(result[1].speakerInference?.evidence, .diarizationCoverage)
        XCTAssertEqual(result[1].speakerID, nil)
    }

    func testDurationAndGapLimitsStayConservative() {
        let long = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 1_400, text: "a long stretch"),
            segment("c", speaker: "speaker_1", start: 1_450, end: 1_800, text: "later."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 1_430, 1_820),
        ]
        let longResult = UnknownFragmentReconciler().reconcile(
            segments: long,
            speakers: speakers,
            intervals: intervals
        )
        XCTAssertNil(longResult[1].speakerInference)

        let manyWords = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment(
                "b",
                speaker: nil,
                start: 250,
                end: 800,
                text: "one two three four",
                words: [
                    TimedWord(text: "one", startMs: 250, endMs: 350),
                    TimedWord(text: "two", startMs: 360, endMs: 460),
                    TimedWord(text: "three", startMs: 470, endMs: 600),
                    TimedWord(text: "four", startMs: 620, endMs: 800),
                ]
            ),
            segment("c", speaker: "speaker_1", start: 850, end: 1_100, text: "later."),
        ]
        let wordIntervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 840, 1_120),
        ]
        let wordResult = UnknownFragmentReconciler().reconcile(
            segments: manyWords,
            speakers: speakers,
            intervals: wordIntervals
        )
        XCTAssertNil(wordResult[1].speakerInference)
    }

    func testParagraphsCanGroupAnInferredFragmentWithoutRewritingCanonicalIDs() {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "there"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "friend."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: reconciled)

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].speakerID, "speaker_1")
        XCTAssertEqual(paragraphs[0].sourceSegmentIDs, ["a", "b", "c"])
        XCTAssertTrue(paragraphs[0].containsInferredAttribution)
        XCTAssertTrue(paragraphs[0].needsReview)
        XCTAssertEqual(reconciled.map(\.speakerID), ["speaker_1", nil, "speaker_1"])
    }

    func testExportKeepsOriginalUnknownSpeakerID() throws {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "there"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "friend."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )
        let transcript = CanonicalTranscript(
            transcriptID: "inference-export",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-09T12:00:00Z",
            source: TranscriptSource(filename: "export.wav", durationMs: 1_000, checksum: "sha256:inference"),
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: reconciled
        )
        try CanonicalTranscriptValidator.validate(transcript)
        let json = try TranscriptJSONExporter.export(transcript)
        XCTAssertTrue(json.contains("\"speaker_id\": null"))
        XCTAssertTrue(json.contains("Unknown speaker"))
        let text = try TranscriptTextExporter.export(transcript)
        XCTAssertTrue(text.contains("Unknown speaker: there"))
    }

    func testManualSpeakerMoveClearsInference() throws {
        let segments = [
            segment("a", speaker: "speaker_1", start: 0, end: 200, text: "Hello"),
            segment("b", speaker: nil, start: 250, end: 400, text: "there"),
            segment("c", speaker: "speaker_1", start: 450, end: 800, text: "friend."),
        ]
        let intervals = [
            interval("speaker_1", 0, 220),
            interval("speaker_1", 430, 820),
        ]
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: segments,
            speakers: speakers,
            intervals: intervals
        )
        let transcript = CanonicalTranscript(
            transcriptID: "inference-manual",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-09T12:00:00Z",
            source: TranscriptSource(filename: "manual.wav", durationMs: 1_000, checksum: "sha256:inference"),
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: reconciled
        )
        let moved = try TranscriptSpeakerLabelEditor.moving(
            segmentID: "b",
            toSpeakerID: "speaker_2",
            in: transcript
        )
        let corrected = try XCTUnwrap(moved.segments.first { $0.id == "b" })
        XCTAssertEqual(corrected.speakerID, "speaker_2")
        XCTAssertEqual(corrected.attributionSource, .manual)
        XCTAssertNil(corrected.speakerInference)
        XCTAssertEqual(
            UnknownFragmentReconciler().reconcile(
                segments: moved.segments,
                speakers: speakers,
                intervals: intervals
            ).first { $0.id == "b" }?.speakerID,
            "speaker_2"
        )
    }

    func testReferenceRunRepairsBoundaryGapsAndLeavesKnownFailuresUnresolved() throws {
        let run = URL(
            fileURLWithPath: "/Users/jake/Meeting Transcripts/meeting--12cc48aa2c740dc50eb637b4b25a274f/runs/767535C4-424D-48BF-A178-E36435C01F12"
        )
        let transcriptURL = run.appending(path: "canonical-transcript.json")
        let diarizationURL = run.appending(path: "diarization.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: transcriptURL.path), "Reference run is not on this machine")

        let original = try CanonicalTranscriptCodec.decode(Data(contentsOf: transcriptURL))
        let diarization = try JSONDecoder().decode(DiarizationRecord.self, from: Data(contentsOf: diarizationURL))
        let intervals = diarization.acousticIntervals(sourceDurationMs: original.source.durationMs)
        let reconciled = UnknownFragmentReconciler().reconcile(
            segments: original.segments,
            speakers: original.speakers,
            intervals: intervals
        )

        XCTAssertEqual(reconciled.count, original.segments.count)
        XCTAssertEqual(reconciled.map(\.speakerID), original.segments.map(\.speakerID))
        XCTAssertEqual(reconciled.map(\.text), original.segments.map(\.text))
        XCTAssertEqual(reconciled.flatMap { $0.words ?? [] }, original.segments.flatMap { $0.words ?? [] })

        let inferred = reconciled.filter(\.hasInferredSpeaker)
        let unresolved = reconciled.filter { $0.speakerID == nil && !$0.hasInferredSpeaker }
        let originalUnknownWords = original.segments.filter { $0.speakerID == nil }.flatMap { $0.words ?? [] }.count
        let remainingUnknownWords = unresolved.flatMap { $0.words ?? [] }.count

        XCTAssertEqual(inferred.count, 39)
        XCTAssertEqual(inferred.filter { $0.speakerInference?.evidence == .diarizationBoundaryGap }.count, 39)
        XCTAssertEqual(unresolved.count, 509)
        XCTAssertEqual(originalUnknownWords, 814)
        XCTAssertEqual(remainingUnknownWords, 771)

        let opening = reconciled.filter { $0.startMs >= 67_000 && $0.startMs <= 71_000 }
        XCTAssertTrue(opening.contains { $0.text == "Hello." && $0.unresolvedSpeakerEvidence == .noCoverage && !$0.hasInferredSpeaker })
        XCTAssertTrue(opening.contains { $0.text == "hey." && $0.unresolvedSpeakerEvidence == .noCoverage && !$0.hasInferredSpeaker })

        let okay = try XCTUnwrap(reconciled.first { $0.startMs == 76_160 && $0.text == "Okay." })
        XCTAssertEqual(okay.unresolvedSpeakerEvidence, .insufficientOverlap)
        XCTAssertNil(okay.speakerInference)

        let contraction = try XCTUnwrap(reconciled.first { $0.startMs == 101_680 && $0.text == "ll" })
        XCTAssertEqual(contraction.unresolvedSpeakerEvidence, .insufficientOverlap)
        XCTAssertNil(contraction.speakerInference)

        let competing = try XCTUnwrap(reconciled.first { $0.startMs == 992_560 })
        XCTAssertEqual(competing.unresolvedSpeakerEvidence, .competingSpeakers)
        XCTAssertTrue(competing.overlap)

        let repairedWe = try XCTUnwrap(reconciled.first { $0.startMs == 181_360 && $0.text == "we" })
        XCTAssertEqual(repairedWe.speakerInference?.speakerID, "speaker_1")
        XCTAssertEqual(repairedWe.speakerInference?.evidence, .diarizationBoundaryGap)

        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: reconciled)
        XCTAssertEqual(paragraphs.flatMap(\.sourceSegmentIDs), original.segments.map(\.id))
        XCTAssertLessThan(paragraphs.count, original.segments.count)
        XCTAssertEqual(paragraphs.count, 917, "959 before the reading-boundary refinement in coo:992.crzj")
        XCTAssertGreaterThan(paragraphs.filter(\.containsInferredAttribution).count, 0)
        XCTAssertTrue(paragraphs.contains { $0.overlap })
    }

    private func segment(
        _ id: String,
        speaker: String?,
        start: Int,
        end: Int,
        text: String,
        overlap: Bool = false,
        words: [TimedWord]? = nil,
        attributionSource: TranscriptSpeakerAttributionSource? = nil
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
            words: words,
            attributionSource: attributionSource
        )
    }

    private func interval(_ speakerID: String, _ startMs: Int, _ endMs: Int) -> AcousticSpeakerInterval {
        AcousticSpeakerInterval(
            speakerID: speakerID,
            startMs: startMs,
            endMs: endMs,
            overlapsAnotherSpeaker: false,
            qualityScore: 1
        )
    }
}
