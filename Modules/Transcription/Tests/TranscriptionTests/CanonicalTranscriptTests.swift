import Foundation
import XCTest
@testable import Transcription

final class CanonicalTranscriptTests: XCTestCase {
    func testSpeakerMergeIncludesInferredTurnsAndEveryExportRemainsValid() throws {
        let original = inferredTranscript()
        let merged = try TranscriptSpeakerLabelEditor.merging(speakerID: "speaker_2", into: "speaker_1", in: original)
        XCTAssertEqual(merged.speakers.map(\.id), ["speaker_1"])
        XCTAssertEqual(merged.segments.first?.speakerID, "speaker_1")
        XCTAssertEqual(merged.segments.first?.attributionSource, .manual)
        XCTAssertNil(merged.segments.first?.speakerInference)
        XCTAssertEqual(merged.segments.map(\.text), original.segments.map(\.text))
        XCTAssertEqual(merged.segments.map(\.words), original.segments.map(\.words))
        XCTAssertEqual(merged.segments.map(\.startMs), original.segments.map(\.startMs))
        XCTAssertEqual(merged.segments.map(\.endMs), original.segments.map(\.endMs))
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(merged))
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try TranscriptExporter.export(merged, as: format).isEmpty)
        }
    }

    func testLoadingAnOldMergeRestoresOnlyMissingInferredSpeakerMetadata() throws {
        let original = inferredTranscript()
        let broken = original.nextRevision(speakers: [original.speakers[0]])
        XCTAssertThrowsError(try TranscriptExporter.knowledgebaseJSON(broken))
        let recovered = try CanonicalTranscriptCodec.decode(CanonicalTranscriptCodec.encode(broken))
        XCTAssertEqual(recovered.speakers, original.speakers)
        XCTAssertEqual(recovered.segments, broken.segments)
        XCTAssertEqual(recovered.revision, broken.revision)
        XCTAssertEqual(recovered.source, broken.source)
        XCTAssertEqual(try CanonicalTranscriptCodec.decode(CanonicalTranscriptCodec.encode(recovered)), recovered)
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try TranscriptExporter.export(recovered, as: format).isEmpty)
        }
    }

    func testMergingSpeakersAfterCombiningRecordingsKeepsExportsValid() throws {
        let original = inferredTranscript()
        let combined = TranscriptRecordingCombiner.combine(
            first: original, second: original, offsetMs: 1_000,
            source: TranscriptSource(filename: "combined.wav", durationMs: 2_000, checksum: "combined")
        )
        let secondSpeaker = try XCTUnwrap(combined.speakerIDMap["speaker_2"])
        let merged = try TranscriptSpeakerLabelEditor.merging(
            speakerID: secondSpeaker, into: "speaker_1", in: combined.transcript
        )
        XCTAssertNil(merged.speakers.first { $0.id == secondSpeaker })
        XCTAssertEqual(merged.segments.last?.speakerID, "speaker_1")
        XCTAssertEqual(merged.segments.last?.startMs, 1_000)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(merged))
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try TranscriptExporter.export(merged, as: format).isEmpty)
        }
    }

    func testMissingSpeakerErrorExplainsTheReference() {
        let error = CanonicalTranscriptValidator.Error.unknownSpeakerReference(segmentID: "turn", speakerID: "missing")
        XCTAssertEqual(error.localizedDescription, "Transcript segment turn refers to missing speaker missing.")
    }

    /// Opt-in verification of saved recordings, without writing to their store.
    func testSavedTranscriptExportsWhenStoreIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBE_TEST_TRANSCRIPT_STORE"] else {
            throw XCTSkip("Set SCRIBE_TEST_TRANSCRIPT_STORE to check saved recordings.")
        }
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil
        ))
        var count = 0
        for case let url as URL in files where url.lastPathComponent == "canonical-transcript.json" {
            let transcript = try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
            for format in TranscriptExportFormat.allCases {
                XCTAssertFalse(try TranscriptExporter.export(transcript, as: format).isEmpty)
            }
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        print("Verified all export formats for \(count) saved transcripts without modifying their files.")
    }

    private func inferredTranscript() -> CanonicalTranscript {
        transcript(
            source: TranscriptSource(filename: "test.wav", durationMs: 1_000, checksum: "test"),
            speakers: [
                TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1"),
                TranscriptSpeaker(id: "speaker_2", identityAssignment: .unmatched, labelSnapshot: "Speaker 2"),
            ],
            segments: [TranscriptSegment(
                id: "inferred", speakerID: nil, speakerLabel: "Unknown speaker",
                startMs: 0, endMs: 100, text: "Hello", overlap: false, timingQuality: .asrWord,
                words: [TimedWord(text: "Hello", startMs: 0, endMs: 100)],
                speakerInference: TranscriptSpeakerInference(
                    speakerID: "speaker_2", speakerLabel: "Speaker 2",
                    evidence: .nearestInterval(distanceMs: 15), provenance: "speaker-turn-attribution-v3"
                )
            )]
        )
    }

    private let fixtureNames = [
        "one-speaker", "two-speakers", "four-speakers", "overlap", "unknown-speaker",
        "no-speech", "long-turns", "unicode", "past-one-hour", "past-twenty-four-hours",
    ]

    func testFixturesValidateAgainstBundledSchemaAndSemanticValidator() throws {
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let schemaValidator = JSONSchemaFixtureValidator(rootSchema: schema)

        for name in fixtureNames {
            let data = try fixtureData(named: name)
            try schemaValidator.validate(try JSONSerialization.jsonObject(with: data))
            try CanonicalTranscriptValidator.validate(try CanonicalTranscriptCodec.decode(data))
        }
    }

    func testFixtureRoundTripPreservesCanonicalFields() throws {
        let transcript = try CanonicalTranscriptCodec.decode(fixtureData(named: "one-speaker"))
        let roundTripped = try CanonicalTranscriptCodec.decode(CanonicalTranscriptCodec.encode(transcript))

        XCTAssertEqual(roundTripped, transcript)
        XCTAssertEqual(transcript.segments.first?.words?.count, 4)
        XCTAssertEqual(transcript.subtitleCueMappings?.first?.parentSegmentID, "segment_001")
    }

    func testOverlapIsPermittedWhenChronologicalOrderIsStable() throws {
        let transcript = try CanonicalTranscriptCodec.decode(fixtureData(named: "overlap"))
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(transcript))
        XCTAssertTrue(transcript.segments.allSatisfy(\.overlap))
    }

    func testValidatorRejectsInvalidBoundsEmptyTextUnknownSpeakerAndOrdering() throws {
        let source = TranscriptSource(filename: "test.wav", durationMs: 1_000, checksum: "sha256:test")
        let speaker = TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")
        let valid = TranscriptSegment(id: "segment_001", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 100, text: "Valid.", overlap: false, timingQuality: .asrWord)

        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "bad-bounds", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 500, endMs: 1_001, text: "Out of range.", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "empty", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 100, text: "  ", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "unknown", speakerID: "speaker_missing", speakerLabel: "Missing", startMs: 0, endMs: 100, text: "Who am I?", overlap: false, timingQuality: .asrWord),
        ])))
        XCTAssertThrowsError(try CanonicalTranscriptValidator.validate(transcript(source: source, speakers: [speaker], segments: [
            TranscriptSegment(id: "later", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 200, endMs: 300, text: "Later.", overlap: false, timingQuality: .asrWord),
            valid,
        ])))
    }

    func testNearestInferenceRoundTripsAndMatchesSchema() throws {
        let built = try SpeakerTurnBuilder().build(words: [RecognizedWord(id: "edge", text: "edge", startMs: 500, endMs: 530,
            enclosingStartMs: 500, enclosingEndMs: 530)], diarizedTurns: [DiarizedSpeakerTurn(speakerID: "A", startMs: 0, endMs: 400)])
        let value = transcript(source: TranscriptSource(filename: "test.wav", durationMs: 1_000, checksum: "sha256:test"), speakers: built.speakers, segments: built.segments)
        let data = try CanonicalTranscriptCodec.encode(value)
        XCTAssertEqual(try CanonicalTranscriptCodec.decode(data), value)
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: CanonicalTranscriptSchema.data) as? [String: Any])
        let validator = JSONSchemaFixtureValidator(rootSchema: schema)
        var document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var segments = try XCTUnwrap(document["segments"] as? [[String: Any]])
        // The schema describes explicit-null export labels; the storage codec
        // omits nil fields. Supply that existing normalization for this check.
        segments[0]["speaker_id"] = NSNull()
        document["segments"] = segments
        try validator.validate(document)
        var inference = try XCTUnwrap(segments[0]["speaker_inference"] as? [String: Any])
        inference["evidence"] = ["type": "nearest_interval", "distance_ms": 251]
        segments[0]["speaker_inference"] = inference
        document["segments"] = segments
        XCTAssertThrowsError(try validator.validate(document))
    }

    private func transcript(source: TranscriptSource, speakers: [TranscriptSpeaker], segments: [TranscriptSegment]) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "validator-test",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-03T12:00:00Z",
            source: source,
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: segments
        )
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}
