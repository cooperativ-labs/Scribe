import AVFoundation
import Foundation
import Speakers
import XCTest
@testable import Transcription

final class TranscriptRecordingCombinerTests: XCTestCase {
    func testTheSecondRecordingFollowsTheFirstOnOneTimeline() throws {
        let first = transcript(
            id: "first",
            durationMs: 10_000,
            speakers: [speaker("speaker_1", "Speaker 1")],
            segments: [segment("segment_001", "speaker_1", "Speaker 1", 0, 4_000, words: [TimedWord(text: "Hello", startMs: 100, endMs: 600)])]
        )
        let second = transcript(
            id: "second",
            durationMs: 5_000,
            speakers: [speaker("speaker_1", "Speaker 1")],
            segments: [segment("segment_001", "speaker_1", "Speaker 1", 500, 2_000, words: [TimedWord(text: "Back", startMs: 500, endMs: 900)])]
        )

        let result = TranscriptRecordingCombiner.combine(
            first: first, second: second, offsetMs: 10_000,
            source: TranscriptSource(filename: "final.m4a", durationMs: 15_000, checksum: "joined")
        )
        let combined = result.transcript

        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(combined))
        XCTAssertEqual(combined.transcriptID, "first")
        XCTAssertEqual(combined.revision, 2)
        XCTAssertEqual(combined.source.durationMs, 15_000)
        XCTAssertEqual(combined.segments.map(\.id), ["segment_001", "segment_002"])
        XCTAssertEqual(combined.segments[1].startMs, 10_500)
        XCTAssertEqual(combined.segments[1].endMs, 12_000)
        XCTAssertEqual(combined.segments[1].words, [TimedWord(text: "Back", startMs: 10_500, endMs: 10_900)])
        XCTAssertEqual(combined.segments[0].words, first.segments[0].words, "the first recording is not moved")
        XCTAssertNotNil(combined.processingOptions[TranscriptRecordingCombiner.processingOptionKey])
    }

    func testOnlyRecognisedOrNamedSpeakersAreJoined() throws {
        let first = transcript(
            id: "first",
            durationMs: 10_000,
            speakers: [
                speaker("speaker_1", "Ada Lovelace", profileID: "ada", assignment: .automatic),
                speaker("speaker_2", "Grace Hopper", assignment: .manual),
                speaker("speaker_3", "Speaker 3"),
            ],
            segments: [
                segment("segment_001", "speaker_1", "Ada Lovelace", 0, 1_000),
                segment("segment_002", "speaker_2", "Grace Hopper", 1_000, 2_000),
                segment("segment_003", "speaker_3", "Speaker 3", 2_000, 3_000),
            ]
        )
        let second = transcript(
            id: "second",
            durationMs: 6_000,
            speakers: [
                // The library knows this is Ada, whatever the label says.
                speaker("speaker_1", "Ada L.", profileID: "ada", assignment: .automatic),
                // Named by hand in both recordings.
                speaker("speaker_2", "grace hopper", assignment: .manual),
                // A generic cluster: the same label does not make it the same person.
                speaker("speaker_3", "Speaker 3"),
            ],
            segments: [
                segment("segment_001", "speaker_1", "Ada L.", 0, 1_000),
                segment("segment_002", "speaker_2", "grace hopper", 1_000, 2_000),
                segment("segment_003", "speaker_3", "Speaker 3", 2_000, 3_000),
                segment("segment_004", nil, "Unknown speaker", 3_000, 4_000),
            ]
        )

        let result = TranscriptRecordingCombiner.combine(
            first: first,
            second: second,
            secondSuggestions: [TranscriptSpeakerSuggestion(
                speakerID: "speaker_3",
                person: SpeakerPersonRef(profileID: UUID(), displayName: "Alan Turing"),
                score: 0.6,
                matcherVersion: "test"
            )],
            offsetMs: 10_000,
            source: TranscriptSource(filename: "final.m4a", durationMs: 16_000, checksum: "joined")
        )
        let combined = result.transcript

        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(combined))
        XCTAssertEqual(result.speakerIDMap, ["speaker_1": "speaker_1", "speaker_2": "speaker_2", "speaker_3": "speaker_4"])
        XCTAssertEqual(combined.speakers.map(\.id), ["speaker_1", "speaker_2", "speaker_3", "speaker_4"])
        XCTAssertEqual(combined.speakers.last?.labelSnapshot, "Speaker 4")
        let appended = Array(combined.segments.suffix(4))
        XCTAssertEqual(appended.map(\.speakerID), ["speaker_1", "speaker_2", "speaker_4", nil])
        XCTAssertEqual(appended.map(\.speakerLabel), ["Ada Lovelace", "Grace Hopper", "Speaker 4", "Unknown speaker"])
        XCTAssertEqual(Set(combined.segments.map(\.id)).count, 7, "segment ids stay unique")
        XCTAssertEqual(result.suggestions.map(\.speakerID), ["speaker_4"], "suggestions follow their speaker")
    }

    func testATurnEndingPastTheMeasuredLengthIsKeptInside() throws {
        let first = transcript(id: "first", durationMs: 4_000, speakers: [], segments: [])
        let second = transcript(
            id: "second",
            durationMs: 3_000,
            speakers: [],
            segments: [segment("segment_001", nil, "Unknown speaker", 2_000, 3_000, words: [TimedWord(text: "bye", startMs: 2_500, endMs: 3_000)])]
        )
        let combined = TranscriptRecordingCombiner.combine(
            first: first, second: second, offsetMs: 4_000,
            source: TranscriptSource(filename: "final.m4a", durationMs: 6_990, checksum: "joined")
        ).transcript

        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(combined))
        XCTAssertEqual(combined.segments.first?.endMs, 6_990)
    }

    // MARK: - Fixtures

    private func transcript(id: String, durationMs: Int, speakers: [TranscriptSpeaker], segments: [TranscriptSegment]) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: id,
            revision: 1,
            status: .complete,
            createdAt: "2026-11-10T09:00:00Z",
            source: TranscriptSource(filename: "\(id).m4a", durationMs: durationMs, checksum: id),
            language: "en",
            languageSource: .detected,
            speakers: speakers,
            segments: segments
        )
    }

    private func speaker(
        _ id: String,
        _ label: String,
        profileID: String? = nil,
        assignment: Transcription.SpeakerIdentityAssignment = .unmatched
    ) -> TranscriptSpeaker {
        TranscriptSpeaker(id: id, profileID: profileID, identityAssignment: assignment, labelSnapshot: label)
    }

    private func segment(
        _ id: String,
        _ speakerID: String?,
        _ label: String,
        _ start: Int,
        _ end: Int,
        words: [TimedWord]? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id, speakerID: speakerID, speakerLabel: label, startMs: start, endMs: end,
            text: "words", overlap: false, timingQuality: words == nil ? .segmentOnly : .asrWord, words: words
        )
    }
}

final class AudioConcatenatorTests: XCTestCase {
    /// Scribe's recordings are AAC in M4A; joining two keeps every sample of
    /// both and reports where the second begins.
    func testTwoAACRecordingsAreJoinedEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Concatenator \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeAAC(named: "first.m4a", in: directory, seconds: 3)
        let second = try writeAAC(named: "second.m4a", in: directory, seconds: 2)
        let destination = directory.appending(path: "joined.m4a")

        let output = try await AudioConcatenator().concatenate([first, second], to: destination)

        let firstDuration = try await AVURLAsset(url: first).load(.duration).seconds
        XCTAssertEqual(output.offsetsMs.count, 2)
        XCTAssertEqual(output.offsetsMs[0], 0)
        XCTAssertEqual(Double(output.offsetsMs[1]), firstDuration * 1_000, accuracy: 1)
        XCTAssertEqual(Double(output.durationMs), 5_000, accuracy: 100)
        let joined = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(joined, 5, accuracy: 0.1)
    }

    func testAFileWithoutAudioIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Concatenator \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try writeAAC(named: "first.m4a", in: directory, seconds: 1)
        let notAudio = directory.appending(path: "notes.m4a")
        try Data("not audio".utf8).write(to: notAudio)

        do {
            _ = try await AudioConcatenator().concatenate([first, notAudio], to: directory.appending(path: "joined.m4a"))
            XCTFail("a file without audio cannot be joined")
        } catch {}
    }

    private func writeAAC(named name: String, in directory: URL, seconds: Double) throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.03) * 0.4 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}
