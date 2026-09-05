import Foundation
import XCTest
@testable import Transcription

@MainActor
final class TranscriptViewModelTests: XCTestCase {
    func testSelectingASegmentLoadsTheSnapshotAndSeeksToItsSourceTime() throws {
        let transcript = try fixture(named: "overlap")
        let snapshot = URL(fileURLWithPath: "/tmp/scribe-overlap-snapshot.flac")
        let playback = PlaybackSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: snapshot, transcript: transcript, jobState: .complete)],
            playback: playback
        )

        XCTAssertEqual(playback.loadedURLs, [snapshot])
        XCTAssertEqual(viewModel.chronologicalSegments.map(\.id), ["segment_001", "segment_002"])

        let segment = try XCTUnwrap(viewModel.chronologicalSegments.last)
        viewModel.select(segment: segment)

        XCTAssertEqual(viewModel.selectedSegmentID, segment.id)
        XCTAssertEqual(playback.soughtMilliseconds, [2_800])
    }

    func testReviewMetadataKeepsLanguageProvenanceTimingLimitationsAndErrorsVisible() throws {
        let transcript = try fixture(named: "unknown-speaker")
        let playback = PlaybackSpy()
        let file = TranscriptReviewFile(
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-unknown-snapshot.flac"),
            transcript: transcript,
            jobState: .completeWithWarnings,
            processingError: "The original source was partially unreadable."
        )
        let viewModel = TranscriptViewModel(files: [file], playback: playback)

        XCTAssertEqual(viewModel.languageDescription, "Language: en (unknown)")
        XCTAssertEqual(viewModel.timingLimitation, "Some timestamps are segment-level estimates rather than word-aligned timings.")
        XCTAssertTrue(viewModel.processingMessages.contains("The original source was partially unreadable."))
        XCTAssertEqual(viewModel.chronologicalSegments.first?.speakerID, nil)
        XCTAssertEqual(viewModel.chronologicalSegments.first?.speakerLabel, "Unknown speaker")
    }

    func testFileExporterWritesEveryRequestedFormatMatchingTheGoldens() throws {
        let transcript = try fixture(named: "two-speakers")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-review-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcomes = FileTranscriptExportWriter().write(transcript, formats: Set(TranscriptExportFormat.allCases), to: directory)

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        for format in TranscriptExportFormat.allCases {
            let expectedURL = try XCTUnwrap(
                Bundle.module.url(forResource: "expected-two-speakers", withExtension: format.fileExtension)
                    ?? Bundle.module.url(forResource: "expected-two-speakers", withExtension: format.fileExtension, subdirectory: "Goldens")
            )
            let destination = directory.appendingPathComponent("interview").appendingPathExtension(format.fileExtension)
            XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: expectedURL), "\(format.rawValue) export drifted")
        }
    }

    func testViewModelRetainsPerFormatExportFailures() throws {
        let playback = PlaybackSpy()
        let failure = TranscriptExportOutcome(format: .subtitles, destinationURL: nil, errorMessage: "Cannot write SRT")
        let success = TranscriptExportOutcome(format: .plainText, destinationURL: URL(fileURLWithPath: "/tmp/review.txt"), errorMessage: nil)
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-snapshot.flac"), transcript: try fixture(named: "one-speaker"), jobState: .complete)],
            playback: playback,
            exportWriter: StubExportWriter(outcomes: [success, failure])
        )

        viewModel.export([.plainText, .subtitles], to: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(viewModel.exportOutcomes, [success, failure])
        XCTAssertTrue(viewModel.exportOutcomes.contains { $0.format == .subtitles && !$0.succeeded })
    }

    func testPlayingASegmentStartsThereAndFollowsTheTurnsUntilTheLastOneEnds() throws {
        let transcript = try fixture(named: "two-speakers")
        let playback = PlaybackSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-two.flac"), transcript: transcript, jobState: .complete)],
            playback: playback
        )
        XCTAssertNil(viewModel.playbackStatus, "nothing plays until asked")

        let first = try XCTUnwrap(viewModel.chronologicalSegments.first)
        viewModel.play(segment: first)

        XCTAssertEqual(playback.soughtMilliseconds, [500])
        XCTAssertEqual(playback.transport, [.play])
        XCTAssertEqual(viewModel.playbackStatus?.speakerLabel, "Alex")
        XCTAssertEqual(viewModel.playbackStatus?.timestamp, "00:00:00.500 – 00:00:03.100")
        XCTAssertEqual(viewModel.playbackStatus?.isPlaying, true)

        // Between turns the readout keeps the speaker who just finished.
        playback.emit(.timeChanged(milliseconds: 3_200))
        XCTAssertEqual(viewModel.playingSegmentID, "segment_001")

        playback.emit(.timeChanged(milliseconds: 3_400))
        XCTAssertEqual(viewModel.playingSegmentID, "segment_002")
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_002", "the highlighted row follows the audio")
        XCTAssertEqual(viewModel.playbackStatus?.speakerLabel, try XCTUnwrap(viewModel.chronologicalSegments.last).speakerLabel)

        playback.emit(.timeChanged(milliseconds: 6_000))
        XCTAssertNil(viewModel.playbackStatus, "playback stops once the last turn has been heard")
        XCTAssertEqual(playback.transport, [.play, .pause])
    }

    func testPauseResumeAndStop() throws {
        let transcript = try fixture(named: "two-speakers")
        let playback = PlaybackSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-two.flac"), transcript: transcript, jobState: .complete)],
            playback: playback
        )

        // With nothing selected the bar starts from the top of the transcript.
        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playingSegmentID, "segment_001")
        XCTAssertEqual(playback.soughtMilliseconds, [500])

        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playbackStatus?.isPlaying, false)
        XCTAssertEqual(viewModel.playingSegmentID, "segment_001", "pausing keeps the position")
        playback.emit(.timeChanged(milliseconds: 4_000))
        XCTAssertEqual(viewModel.playingSegmentID, "segment_001", "a stale time event while paused changes nothing")

        viewModel.togglePlayback()
        XCTAssertEqual(playback.transport, [.play, .pause, .play])
        XCTAssertEqual(playback.soughtMilliseconds, [500], "resuming does not seek back to the start of the turn")

        viewModel.stopPlayback()
        XCTAssertNil(viewModel.playbackStatus)
        XCTAssertEqual(playback.transport, [.play, .pause, .play, .pause])

        // After a stop the selected turn is where the next play begins.
        let second = try XCTUnwrap(viewModel.chronologicalSegments.last)
        viewModel.select(segment: second)
        viewModel.togglePlayback()
        XCTAssertEqual(viewModel.playingSegmentID, "segment_002")
    }

    func testSwitchingFilesStopsPlayback() throws {
        let playback = PlaybackSpy()
        let one = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/one.flac"), transcript: try fixture(named: "one-speaker"), jobState: .complete)
        let two = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/two.flac"), transcript: try fixture(named: "two-speakers"), jobState: .complete)
        let viewModel = TranscriptViewModel(files: [one, two], playback: playback)

        viewModel.play(segment: try XCTUnwrap(viewModel.chronologicalSegments.first))
        viewModel.selectedFileID = two.id

        XCTAssertNil(viewModel.playbackStatus)
        XCTAssertEqual(playback.transport, [.play, .pause])
    }

    func testDeletingRemovesTheFileFromTheHostAndMovesTheSelection() throws {
        let playback = PlaybackSpy()
        let deleter = DeleterSpy()
        let one = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/one.flac"), transcript: try fixture(named: "one-speaker"), jobState: .complete)
        let two = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/two.flac"), transcript: try fixture(named: "two-speakers"), jobState: .complete)
        let inFlight = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/three.flac"), transcript: nil, jobState: .processing(progress: nil))
        let viewModel = TranscriptViewModel(files: [one, two, inFlight], playback: playback, fileDeleter: deleter)

        XCTAssertFalse(viewModel.canDelete(inFlight))
        viewModel.delete(fileID: inFlight.id)
        XCTAssertEqual(viewModel.files.count, 3, "a job still running is not deletable")
        XCTAssertEqual(deleter.deleted, [])

        viewModel.play(segment: try XCTUnwrap(viewModel.chronologicalSegments.first))
        viewModel.delete(fileID: one.id)

        XCTAssertEqual(deleter.deleted, [one.id])
        XCTAssertEqual(viewModel.files.map(\.id), [two.id, inFlight.id])
        XCTAssertEqual(viewModel.selectedFileID, two.id, "the selection moves to the next row")
        XCTAssertNil(viewModel.playbackStatus, "deleting the playing file stops playback")
        XCTAssertEqual(playback.loadedURLs.last, two.sourceSnapshotURL)
    }

    func testAFailedDeletionKeepsTheFileAndReportsWhy() throws {
        let deleter = DeleterSpy()
        deleter.error = CocoaError(.fileNoSuchFile)
        let one = TranscriptReviewFile(sourceSnapshotURL: URL(fileURLWithPath: "/tmp/one.flac"), transcript: try fixture(named: "one-speaker"), jobState: .complete)
        let viewModel = TranscriptViewModel(files: [one], playback: PlaybackSpy(), fileDeleter: deleter)

        viewModel.delete(fileID: one.id)

        XCTAssertEqual(viewModel.files.map(\.id), [one.id])
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
        XCTAssertTrue(viewModel.speakerActionMessage?.text.hasPrefix("Could not delete") == true)
    }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

@MainActor
private final class PlaybackSpy: TranscriptPlaybackSeeking {
    enum Transport: Equatable { case play, pause }

    private(set) var loadedURLs: [URL] = []
    private(set) var soughtMilliseconds: [Int] = []
    private(set) var transport: [Transport] = []
    private var observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?

    func load(sourceSnapshotURL: URL) { loadedURLs.append(sourceSnapshotURL) }
    func seek(toMilliseconds milliseconds: Int) { soughtMilliseconds.append(milliseconds) }
    func play() { transport.append(.play) }
    func pause() { transport.append(.pause) }
    func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?) { self.observer = observer }

    func emit(_ event: TranscriptPlaybackEvent) { observer?(event) }
}

private final class DeleterSpy: TranscriptFileDeleting, @unchecked Sendable {
    var error: (any Error)?
    private(set) var deleted: [TranscriptReviewFile.ID] = []

    func delete(fileID: TranscriptReviewFile.ID) throws {
        if let error { throw error }
        deleted.append(fileID)
    }
}

private struct StubExportWriter: TranscriptExportWriting {
    let outcomes: [TranscriptExportOutcome]

    func write(
        _: CanonicalTranscript,
        formats _: Set<TranscriptExportFormat>,
        to _: URL
    ) -> [TranscriptExportOutcome] { outcomes }
}
