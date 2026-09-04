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

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

@MainActor
private final class PlaybackSpy: TranscriptPlaybackSeeking {
    private(set) var loadedURLs: [URL] = []
    private(set) var soughtMilliseconds: [Int] = []

    func load(sourceSnapshotURL: URL) { loadedURLs.append(sourceSnapshotURL) }
    func seek(toMilliseconds milliseconds: Int) { soughtMilliseconds.append(milliseconds) }
}

private struct StubExportWriter: TranscriptExportWriting {
    let outcomes: [TranscriptExportOutcome]

    func write(
        _: CanonicalTranscript,
        formats _: Set<TranscriptExportFormat>,
        to _: URL
    ) -> [TranscriptExportOutcome] { outcomes }
}
