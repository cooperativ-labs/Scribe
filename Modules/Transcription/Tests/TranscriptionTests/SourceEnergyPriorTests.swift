import Foundation
import ScribeAppCore
import Speakers
import XCTest
@testable import Transcription

final class SourceEnergyPriorTests: XCTestCase {
    private func timeline(micEnd: Int = 100, bothLoud: Bool = false) -> SourceEnergyTimeline {
        .init(windows: (0..<200).map { i in
            .init(startMs: i * 100, endMs: (i + 1) * 100,
                  microphonePower: i < micEnd ? 0.01 : 0.000001,
                  systemPower: bothLoud || i >= micEnd ? 0.01 : 0.000001)
        })
    }
    private let intervals = [AcousticSpeakerInterval(speakerID: "local", startMs: 0, endMs: 10_000),
                             AcousticSpeakerInterval(speakerID: "remote", startMs: 10_000, endMs: 20_000)]

    func testSelectsCanonicalClusterAndRejectsDoubleTalkSilenceShortEvidenceAndTies() throws {
        let prior = try XCTUnwrap(SourceEnergyPrior(timeline: timeline(), intervals: intervals))
        XCTAssertEqual(prior.selection.speakerID, "speaker_1")
        XCTAssertEqual(prior.selection.agreement, 1)
        XCTAssertNil(SourceEnergyPrior(timeline: timeline(bothLoud: true), intervals: intervals))
        XCTAssertNil(SourceEnergyPrior(timeline: timeline(micEnd: 49), intervals: intervals))
        XCTAssertNil(SourceEnergyPrior(timeline: timeline(micEnd: 95), intervals: intervals), "threshold is exclusive")
        XCTAssertNotNil(SourceEnergyPrior(timeline: timeline(micEnd: 96), intervals: intervals))
        XCTAssertNil(SourceEnergyPrior(timeline: timeline(), intervals: [
            .init(speakerID: "a", startMs: 0, endMs: 5_000), .init(speakerID: "b", startMs: 5_000, endMs: 10_000)]))
        XCTAssertNil(SourceEnergyPrior(timeline: .init(windows: [.init(startMs: 0, endMs: 100, microphonePower: 0, systemPower: 0)]), intervals: intervals))
    }

    func testOverlapAndMissingCaptureCannotIdentifyOwner() {
        XCTAssertNil(SourceEnergyPrior(timeline: timeline(), intervals: intervals + [
            .init(speakerID: "other", startMs: 0, endMs: 10_000)]))
        let missing = SourceEnergyTimeline(windows: (0..<100).map {
            .init(startMs: $0 * 100, endMs: ($0 + 1) * 100, microphonePower: 0.1, systemPower: 0, bothTracksPresent: false)
        })
        XCTAssertNil(SourceEnergyPrior(timeline: missing, intervals: intervals))
        let loud = SourceEnergyTimeline.Window(startMs: 0, endMs: 100, microphonePower: 1, systemPower: 0.001)
        XCTAssertFalse(loud.microphoneDominant, "a ratio alone must not override double-talk")
    }

    func testSourceConfidenceSupplementsButDoesNotChangeIdentityOrManualLabels() throws {
        let prior = try XCTUnwrap(SourceEnergyPrior(timeline: timeline(), intervals: intervals))
        let local = segment("a", "speaker_1", 100, 200)
        let adjusted = prior.confidenceAdjusted(local)
        XCTAssertEqual(adjusted.speakerID, local.speakerID)
        XCTAssertGreaterThan(try XCTUnwrap(adjusted.speakerConfidence), 0.5)
        XCTAssertLessThan(try XCTUnwrap(prior.confidenceAdjusted(segment("b", "speaker_2", 100, 200)).speakerConfidence), 0.5)
        let manual = segment("manual", "speaker_2", 100, 200, manual: true)
        XCTAssertEqual(prior.confidenceAdjusted(manual), manual)
        let overlap = segment("overlap", "speaker_1", 100, 200, overlap: true)
        XCTAssertEqual(prior.confidenceAdjusted(overlap), overlap)
    }

    func testSourceFillsBoundedOneNeighborHoleOnlyWithNoCompetingIntervals() throws {
        let acoustic = [AcousticSpeakerInterval(speakerID: "local", startMs: 0, endMs: 9_000), intervals[1]]
        let prior = try XCTUnwrap(SourceEnergyPrior(timeline: timeline(), intervals: acoustic))
        let segments = [segment("a", "speaker_1", 8_500, 9_000), segment("b", nil, 9_100, 9_400)]
        let speakers = [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Local")]
        let baseline = UnknownFragmentReconciler().reconcile(segments: segments, speakers: speakers, intervals: acoustic)
        XCTAssertNil(baseline[1].effectiveSpeakerID)
        let result = UnknownFragmentReconciler().reconcile(segments: segments, speakers: speakers, intervals: acoustic, sourceEnergyPrior: prior)
        XCTAssertNil(result[1].speakerID)
        XCTAssertEqual(result[1].speakerInference?.evidence, .sourceEnergy)
        XCTAssertEqual(result[1].effectiveSpeakerID, "speaker_1")
        let blocked = UnknownFragmentReconciler().reconcile(segments: segments, speakers: speakers,
            intervals: acoustic + [.init(speakerID: "remote", startMs: 9_050, endMs: 9_450)], sourceEnergyPrior: prior)
        XCTAssertNil(blocked[1].effectiveSpeakerID)
        let encoded = try JSONEncoder().encode(result[1])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: encoded), result[1])
    }

    func testLegacyRequestsStayOffAndOptInChangesFingerprint() throws {
        let request = TranscriptionRequest(sourceURL: URL(fileURLWithPath: "/tmp/test.wav"), modelProfileID: "default")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "microphoneSpeakerPrior")
        let old = try JSONDecoder().decode(TranscriptionRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotEqual(old.microphoneSpeakerPrior, true)
        XCTAssertNotEqual(ImportConfiguration(modelProfileID: "default").fingerprint,
                          ImportConfiguration(modelProfileID: "default", microphoneSpeakerPrior: true).fingerprint)
    }

    func testAssemblyOptInLabelsMeOrOwnerAndPreservesExplicitIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write<T: Encodable>(_ value: T, _ file: String) throws {
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent(file))
        }
        try write(PreparedAudioRecord(preparedAudioPath: "prepared.wav", sourceDurationSeconds: 20, sampleRate: 16_000, channels: 1), "prepare.json")
        try write(ReconciledWordsRecord(words: [.init(id: "w1", text: "Hello", startMs: 100, endMs: 500, enclosingStartMs: 0, enclosingEndMs: 1_000)], droppedDuplicateTokenCount: 0, warnings: []), "words.json")
        try write(DiarizationRecord(intervals: [
            .init(speakerID: "local", startSeconds: 0, endSeconds: 10, qualityScore: 1, overlapsAnotherSpeaker: false),
            .init(speakerID: "remote", startSeconds: 10, endSeconds: 20, qualityScore: 1, overlapsAnotherSpeaker: false)
        ], sourceDurationSeconds: 20, engine: nil, configuration: nil, clusteringDiagnostics: nil), "diarization.json")
        try AudioPreparationService.commitSourceEnergy(timeline(), in: root)
        let store = try SpeakerProfileStore(directoryURL: root.appendingPathComponent("library"))
        let person = try await store.createProfile(.init(displayName: "Owner"))
        for enabled in [false, true] {
            let request = TranscriptionRequest(sourceURL: root.appendingPathComponent("final.m4a"), speakerMatching: .disabled,
                microphoneSpeakerPrior: enabled, modelProfileID: "default", title: "Remote call")
            let job = TranscriptionJob(request: request, sourceSnapshotURL: request.sourceURL, runDirectoryURL: root,
                sourceFingerprint: "hash", modelFingerprint: "model", configurationFingerprint: "config")
            let runner = TranscriptAssemblyStageRunner(speakerLibrary: store)
            _ = try await runner.run(stage: .assembling, job: job)
            _ = try await runner.run(stage: .matchingSpeakers, job: job)
            var result = try CanonicalTranscriptCodec.decode(Data(contentsOf: root.appendingPathComponent("canonical-transcript.json")))
            XCTAssertEqual(result.speakers.first?.labelSnapshot, enabled ? "Me" : "Speaker 1")
            XCTAssertEqual(result.title, "Remote call")
            if enabled {
                try await store.setOwner(profileID: person.id)
                _ = try await runner.run(stage: .matchingSpeakers, job: job)
                result = try CanonicalTranscriptCodec.decode(Data(contentsOf: root.appendingPathComponent("canonical-transcript.json")))
                XCTAssertEqual(result.speakers.first?.profileID, person.id.uuidString)
                XCTAssertEqual(result.segments.first?.speakerLabel, "Owner")
                let other = try await store.createProfile(.init(displayName: "Other"))
                try await store.setOwner(profileID: other.id)
                _ = try await runner.run(stage: .matchingSpeakers, job: job)
                result = try CanonicalTranscriptCodec.decode(Data(contentsOf: root.appendingPathComponent("canonical-transcript.json")))
                XCTAssertEqual(result.speakers.first?.profileID, person.id.uuidString)
            }
        }
    }

    private func segment(_ id: String, _ speaker: String?, _ start: Int, _ end: Int, manual: Bool = false, overlap: Bool = false) -> TranscriptSegment {
        .init(id: id, speakerID: speaker, speakerLabel: speaker ?? "Unknown", startMs: start, endMs: end,
              text: "word", overlap: overlap, timingQuality: .asrWord, speakerConfidence: 0.5,
              words: [.init(text: "word", startMs: start, endMs: end)], attributionSource: manual ? .manual : nil)
    }
}
