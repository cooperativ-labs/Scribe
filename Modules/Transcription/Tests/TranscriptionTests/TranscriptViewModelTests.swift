import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

@MainActor
final class TranscriptViewModelTests: XCTestCase {

    func testSpeakerCeilingIsDescribedInReprocessConfirmation() {
        let session = TranscriptReprocessSession(fileID: "test", displayName: "Meeting", speakerCount: .upTo(4))
        XCTAssertEqual(session.speakerCountDescription, "up to 4 speakers")
    }

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

    func testTheVocabularyRouteIsOfferedOnlyWhenTheHostSuppliesOne() throws {
        let transcript = try fixture(named: "overlap")
        let file = TranscriptReviewFile(
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-vocabulary-snapshot.flac"),
            transcript: transcript,
            jobState: .complete
        )

        let withoutRoute = TranscriptViewModel(files: [file], playback: PlaybackSpy())
        XCTAssertFalse(withoutRoute.canOpenVocabularySettings)
        // Calling it anyway must be inert rather than a crash: the toolbar hides
        // the button, but a keyboard route could still reach the model.
        withoutRoute.openVocabulary()

        var opened = 0
        let withRoute = TranscriptViewModel(
            files: [file],
            playback: PlaybackSpy(),
            openVocabularySettings: { opened += 1 }
        )
        XCTAssertTrue(withRoute.canOpenVocabularySettings)
        withRoute.openVocabulary()
        XCTAssertEqual(opened, 1)
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

        XCTAssertEqual(outcomes.count, TranscriptExportFormat.allCases.count)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        for format in TranscriptExportFormat.allCases {
            let destination = directory.appendingPathComponent("interview").appendingPathExtension(format.fileExtension)
            if format == .knowledgebase {
                XCTAssertEqual(try Data(contentsOf: destination), try KnowledgebaseTranscriptExporter.data(transcript))
            } else {
                let expectedURL = try XCTUnwrap(
                    Bundle.module.url(forResource: "expected-two-speakers", withExtension: format.fileExtension)
                        ?? Bundle.module.url(forResource: "expected-two-speakers", withExtension: format.fileExtension, subdirectory: "Goldens")
                )
                XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: expectedURL), "\(format.rawValue) export drifted")
            }
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

    func testCopyKnowledgebaseUsesTheSchemaBackedDocument() async throws {
        let transcript = try fixture(named: "one-speaker")
        let clipboard = ClipboardSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(
                sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-snapshot.flac"),
                transcript: transcript,
                jobState: .complete
            )],
            playback: PlaybackSpy(),
            clipboard: clipboard
        )

        await viewModel.copyKnowledgebaseToClipboard()

        XCTAssertEqual(clipboard.text, try TranscriptExporter.knowledgebaseJSON(transcript))
        XCTAssertEqual(viewModel.exportMessage, TranscriptExportMessage(text: "Copied Knowledgebase JSON to the clipboard.", isFailure: false))
    }

    func testFileExporterWritesToTheExactFileTheSavePanelChose() throws {
        let transcript = try fixture(named: "two-speakers")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-named-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("weekly notes.txt")

        let outcome = FileTranscriptExportWriter().write(transcript, format: .plainText, toFile: destination)

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.destinationURL, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), try TranscriptExporter.plainText(transcript))
    }

    func testFileExporterHonorsAChosenBasenameForEveryFormat() throws {
        let transcript = try fixture(named: "two-speakers")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-basename-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcomes = FileTranscriptExportWriter().write(
            transcript,
            formats: Set(TranscriptExportFormat.allCases),
            to: directory,
            basename: "weekly notes"
        )

        XCTAssertEqual(outcomes.count, TranscriptExportFormat.allCases.count)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        for format in TranscriptExportFormat.allCases {
            let url = directory.appendingPathComponent("weekly notes").appendingPathExtension(format.fileExtension)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("interview.txt").path),
            "the transcript title must not be used when a Save panel name was chosen"
        )
    }

    func testViewModelExportsASingleFormatToTheChosenFile() throws {
        let transcript = try fixture(named: "one-speaker")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-vm-file-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("handoff.srt")
        let viewModel = TranscriptViewModel(
            files: [
                TranscriptReviewFile(
                    sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-snapshot.flac"),
                    transcript: transcript,
                    jobState: .complete
                )
            ],
            playback: PlaybackSpy()
        )

        viewModel.export(.subtitles, toFile: destination)

        XCTAssertEqual(viewModel.exportOutcomes.count, 1)
        XCTAssertEqual(viewModel.exportOutcomes.first?.destinationURL, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), try TranscriptExporter.srt(transcript))
    }

    func testSavePanelURLBecomesAFolderAndSharedBasename() {
        let txt = TranscriptExportDestination.fromSaveURL(URL(fileURLWithPath: "/Users/jake/Desktop/Weekly Standup.txt"))
        XCTAssertEqual(txt.directoryURL.path, "/Users/jake/Desktop")
        XCTAssertEqual(txt.basename, "Weekly Standup")

        let untitled = TranscriptExportDestination.fromSaveURL(URL(fileURLWithPath: "/Users/jake/Desktop/Weekly Standup"))
        XCTAssertEqual(untitled.basename, "Weekly Standup")

        let dotted = TranscriptExportDestination.fromSaveURL(URL(fileURLWithPath: "/tmp/my.meeting.notes"))
        XCTAssertEqual(dotted.basename, "my.meeting.notes")
    }

    func testSavePanelStripsTheCompoundKnowledgebaseExtensionFromASharedBasename() {
        let destination = TranscriptExportDestination.fromSaveURL(
            URL(fileURLWithPath: "/tmp/Weekly sync.kb.json")
        )

        XCTAssertEqual(destination.directoryURL.path, "/tmp")
        XCTAssertEqual(destination.basename, "Weekly sync")
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

    func testReprocessConfirmationSheetShowsProgressAndCompletion() async throws {
        let transcript = try fixture(named: "two-speakers")
        let file = TranscriptReviewFile(
            id: "revision-31-run",
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/standup.flac"),
            transcript: transcript,
            jobState: .complete
        )
        let reprocessor = ReprocessorSpy()
        reprocessor.queuedRunID = "new-run-42"
        let viewModel = TranscriptViewModel(files: [file], playback: PlaybackSpy(), reprocessor: reprocessor)

        viewModel.presentReprocessConfirmation(speakerCount: .known(2))
        XCTAssertEqual(viewModel.reprocessSession?.phase, .confirming)
        XCTAssertEqual(viewModel.reprocessSession?.speakerCount, .known(2))
        XCTAssertTrue(reprocessor.requests.isEmpty, "Nothing is queued until confirmation.")

        await viewModel.confirmReprocess()
        XCTAssertEqual(reprocessor.requests.count, 1)
        XCTAssertEqual(viewModel.reprocessSession?.phase, .queued)
        XCTAssertEqual(viewModel.reprocessSession?.queuedRunID, "new-run-42")

        viewModel.applyReprocessProgress(runID: "new-run-42", stage: .diarizing)
        guard case let .processing(label, progress) = viewModel.reprocessSession?.phase else {
            return XCTFail("Expected processing phase")
        }
        XCTAssertEqual(label, TranscriptionJobState.diarizing.progressLabel)
        XCTAssertEqual(progress, TranscriptionJobState.diarizing.progressFractionOnStart)

        viewModel.applyReprocessCheckpoint(runID: "new-run-42", stage: .diarizing)
        guard case let .processing(_, checkpointProgress) = viewModel.reprocessSession?.phase else {
            return XCTFail("Expected processing phase after checkpoint")
        }
        XCTAssertEqual(checkpointProgress, TranscriptionJobState.diarizing.progressFractionOnCheckpoint)

        viewModel.finishReprocess(runID: "new-run-42", success: true)
        XCTAssertEqual(viewModel.reprocessSession?.phase, .complete)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, false)
        XCTAssertTrue(viewModel.speakerActionMessage?.text.contains("Finished re-transcribing") == true)
    }

    func testReprocessIsUnavailableWhileAJobIsStillProcessing() throws {
        let file = TranscriptReviewFile(
            id: "in-flight",
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/live.flac"),
            transcript: nil,
            jobState: .processing(progress: 0.4)
        )
        let viewModel = TranscriptViewModel(files: [file], playback: PlaybackSpy(), reprocessor: ReprocessorSpy())

        XCTAssertFalse(viewModel.canReprocess)
    }

    func testRetranscribeSendsTheFileIDToTheHostWithoutEditingTheTranscript() async throws {
        let transcript = try fixture(named: "two-speakers")
        let file = TranscriptReviewFile(
            id: "revision-30-run",
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/standup.flac"),
            transcript: transcript,
            jobState: .complete
        )
        let retranscriber = RetranscriberSpy()
        let viewModel = TranscriptViewModel(files: [file], playback: PlaybackSpy(), retranscriber: retranscriber)

        XCTAssertTrue(viewModel.canRetranscribe(file))
        await viewModel.retranscribe(fileID: file.id)

        XCTAssertEqual(retranscriber.fileIDs, [file.id])
        XCTAssertEqual(viewModel.selectedTranscript?.revision, transcript.revision, "Retranscribing must not overwrite the reviewed revision.")
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, false)
        XCTAssertEqual(viewModel.speakerActionMessage?.text, "Queued a new transcription.")
    }

    func testRetranscribeIsUnavailableWhileAJobIsStillProcessing() throws {
        let file = TranscriptReviewFile(
            id: "in-flight",
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/live.flac"),
            transcript: nil,
            jobState: .processing(progress: 0.4)
        )
        let viewModel = TranscriptViewModel(files: [file], playback: PlaybackSpy(), retranscriber: RetranscriberSpy())

        XCTAssertFalse(viewModel.canRetranscribe(file))
    }

    func testSwitchingLayoutsPreservesPlaybackPositionSelectionAndCanonicalSegments() throws {
        let transcript = groupingTranscript()
        let playback = PlaybackSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(
                sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-grouping-snapshot.flac"),
                transcript: transcript,
                jobState: .complete
            )],
            playback: playback
        )
        let original = try XCTUnwrap(viewModel.selectedTranscript)

        let exports = try TranscriptExportFormat.allCases.map { try TranscriptExporter.export(original, as: $0) }

        XCTAssertEqual(viewModel.reviewLayout, .segments)
        XCTAssertEqual(viewModel.chronologicalSegments.map(\.id), ["seg_a", "seg_b", "seg_ack", "seg_c"])
        XCTAssertEqual(viewModel.chronologicalParagraphs.map(\.sourceSegmentIDs), [["seg_a", "seg_b", "seg_c"]])

        let second = try XCTUnwrap(viewModel.chronologicalSegments.first { $0.id == "seg_b" })
        viewModel.select(segment: second)
        viewModel.seek(toMilliseconds: 700)
        let seeksAfterSelection = playback.soughtMilliseconds

        viewModel.reviewLayout = .paragraphs
        XCTAssertEqual(viewModel.selectedSegmentID, "seg_b")
        XCTAssertEqual(viewModel.playheadMilliseconds, 700)
        XCTAssertEqual(viewModel.selectedParagraphID, viewModel.chronologicalParagraphs[0].id)
        XCTAssertEqual(playback.soughtMilliseconds, seeksAfterSelection, "switching views must not move the play head")
        XCTAssertEqual(viewModel.selectedTranscript, original)

        viewModel.reviewLayout = .segments
        XCTAssertEqual(viewModel.selectedSegmentID, "seg_b")
        XCTAssertEqual(viewModel.playheadMilliseconds, 700)
        XCTAssertEqual(viewModel.selectedTranscript?.segments, original.segments)
        XCTAssertEqual(viewModel.selectedTranscript?.speakers, original.speakers)
        let after = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(try TranscriptExportFormat.allCases.map { try TranscriptExporter.export(after, as: $0) }, exports)
        XCTAssertEqual(after.subtitleCueMappings, original.subtitleCueMappings)
    }

    func testParagraphPlaybackAndNeighbourNavigationKeepSourceMappings() throws {
        let transcript = groupingTranscript()
        let playback = PlaybackSpy()
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(
                sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-grouping-play.flac"),
                transcript: transcript,
                jobState: .complete
            )],
            playback: playback
        )
        viewModel.reviewLayout = .paragraphs
        let firstParagraph = try XCTUnwrap(viewModel.chronologicalParagraphs.first)
        viewModel.play(paragraph: firstParagraph)

        XCTAssertEqual(viewModel.playingSegmentID, "seg_a")
        XCTAssertEqual(viewModel.playingParagraphID, firstParagraph.id)
        XCTAssertEqual(viewModel.playheadMilliseconds, 0)
        XCTAssertEqual(playback.transport, [.play])

        let aside = try XCTUnwrap(firstParagraph.asides.first)
        viewModel.play(paragraph: aside)
        XCTAssertEqual(viewModel.playheadMilliseconds, 1_050)
        XCTAssertEqual(viewModel.playingSegmentID, "seg_ack")
        XCTAssertEqual(viewModel.selectedSegmentID, "seg_ack")
        XCTAssertEqual(viewModel.playingParagraphID, firstParagraph.id)
        XCTAssertEqual(viewModel.primarySegment(for: firstParagraph)?.id, "seg_b", "main speaker actions never target the aside")
        viewModel.selectNeighbouringSegment(offset: 1)
        XCTAssertEqual(viewModel.selectedSegmentID, "seg_ack", "the only paragraph has no next neighbour")

        playback.emit(.timeChanged(milliseconds: 1_100))
        viewModel.reviewLayout = .segments
        XCTAssertEqual(viewModel.playingSegmentID, "seg_ack")
        XCTAssertEqual(viewModel.playheadMilliseconds, 1_100)
        XCTAssertTrue(viewModel.isPlaying)
    }

    func testAsidesRemainSearchableFilterableAndSelectTheirCanonicalTurn() throws {
        let transcript = groupingTranscript(asideOverlap: true)
        let viewModel = TranscriptViewModel(files: [TranscriptReviewFile(
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/asides.flac"),
            transcript: transcript, jobState: .complete
        )], playback: PlaybackSpy())
        viewModel.reviewLayout = .paragraphs
        let paragraph = try XCTUnwrap(viewModel.chronologicalParagraphs.first)
        XCTAssertEqual(paragraph.asides.count, 1)
        XCTAssertTrue(paragraph.needsReview)
        viewModel.searchText = "Mm-hm"
        XCTAssertEqual(viewModel.visibleParagraphs.count, 1)
        viewModel.searchText = "Speaker 2"
        XCTAssertEqual(viewModel.visibleParagraphs.count, 1)
        viewModel.searchText = ""
        viewModel.speakerFilterID = "speaker_2"
        XCTAssertEqual(viewModel.visibleParagraphs.count, 1)
        viewModel.reviewFilter = .overlap
        XCTAssertEqual(viewModel.visibleParagraphs.count, 1)
        viewModel.reviewFilter = .needsReview
        XCTAssertEqual(viewModel.visibleParagraphs.count, 1)
        let aside = paragraph.asides[0]
        let source = try XCTUnwrap(viewModel.primarySegment(for: aside))
        viewModel.select(segment: source)
        XCTAssertEqual(viewModel.selectedSegmentID, "seg_ack")
        XCTAssertEqual(viewModel.selectedParagraphID, paragraph.id)
        viewModel.reviewLayout = .segments
        XCTAssertEqual(viewModel.visibleSegments.map(\.id), ["seg_ack"])
        XCTAssertEqual(viewModel.selectedTranscript, transcript)
    }

    private func groupingTranscript(asideOverlap: Bool = false) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "paragraph-views",
            revision: 1,
            status: .complete,
            createdAt: "2026-09-09T12:00:00Z",
            source: TranscriptSource(filename: "grouping.flac", durationMs: 5_000, checksum: "sha256:grouping"),
            language: "en",
            languageSource: .detected,
            speakers: [
                TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1"),
                TranscriptSpeaker(id: "speaker_2", identityAssignment: .unmatched, labelSnapshot: "Speaker 2"),
            ],
            segments: [
                TranscriptSegment(
                    id: "seg_a",
                    speakerID: "speaker_1",
                    speakerLabel: "Speaker 1",
                    startMs: 0,
                    endMs: 400,
                    text: "That's fine.",
                    overlap: false,
                    timingQuality: .asrWord,
                    words: [
                        TimedWord(text: "That's", startMs: 0, endMs: 200),
                        TimedWord(text: "fine.", startMs: 220, endMs: 400),
                    ]
                ),
                TranscriptSegment(
                    id: "seg_b",
                    speakerID: "speaker_1",
                    speakerLabel: "Speaker 1",
                    startMs: 450,
                    endMs: 1_000,
                    text: "We can wait.",
                    overlap: false,
                    timingQuality: .asrWord,
                    words: [
                        TimedWord(text: "We", startMs: 450, endMs: 600),
                        TimedWord(text: "can", startMs: 620, endMs: 780),
                        TimedWord(text: "wait.", startMs: 800, endMs: 1_000),
                    ]
                ),
                TranscriptSegment(
                    id: "seg_ack",
                    speakerID: "speaker_2",
                    speakerLabel: "Speaker 2",
                    startMs: 1_050,
                    endMs: 1_300,
                    text: "Mm-hm.",
                    overlap: asideOverlap,
                    timingQuality: .asrWord,
                    words: [TimedWord(text: "Mm-hm.", startMs: 1_050, endMs: 1_300)]
                ),
                TranscriptSegment(
                    id: "seg_c",
                    speakerID: "speaker_1",
                    speakerLabel: "Speaker 1",
                    startMs: 1_350,
                    endMs: 1_800,
                    text: "Anyway.",
                    overlap: false,
                    timingQuality: .asrWord,
                    words: [TimedWord(text: "Anyway.", startMs: 1_350, endMs: 1_800)]
                ),
            ]
        )
    }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

@MainActor
final class TranscriptViewModelImportTests: XCTestCase {
    func testDroppedFilesGoToTheHostImporterAndTheOutcomeIsShown() async {
        let importer = ImporterSpy()
        importer.outcome = TranscriptImportOutcome(queuedCount: 2)
        let viewModel = TranscriptViewModel(files: [], playback: PlaybackSpy(), fileImporter: importer)
        let urls = [URL(fileURLWithPath: "/tmp/a.wav"), URL(fileURLWithPath: "/tmp/b.m4a")]

        XCTAssertTrue(viewModel.canImportFiles)
        await viewModel.importFiles(at: urls)

        XCTAssertEqual(importer.imported, [urls])
        XCTAssertEqual(viewModel.importMessage?.text, "Queued 2 files for transcription.")
        XCTAssertEqual(viewModel.importMessage?.isFailure, false)
        XCTAssertFalse(viewModel.isImporting)

        viewModel.dismissImportMessage()
        XCTAssertNil(viewModel.importMessage)
    }

    func testARefusedDropShowsTheHostsReasonAsAFailure() async {
        let importer = ImporterSpy()
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        importer.outcome = TranscriptImportOutcome(queuedCount: 0, refusals: [.init(url: url, message: "notes.txt is not media.")])
        let viewModel = TranscriptViewModel(files: [], playback: PlaybackSpy(), fileImporter: importer)

        await viewModel.importFiles(at: [url])

        XCTAssertEqual(viewModel.importMessage?.text, "notes.txt is not media.")
        XCTAssertEqual(viewModel.importMessage?.isFailure, true)
    }

    func testAMixedDropCountsBothQueuedAndRefused() {
        let outcome = TranscriptImportOutcome(
            queuedCount: 1,
            refusals: [.init(url: URL(fileURLWithPath: "/tmp/x"), message: "x"), .init(url: URL(fileURLWithPath: "/tmp/y"), message: "y")]
        )
        XCTAssertEqual(outcome.summary, "Queued 1 file for transcription; 2 could not be queued.")
        XCTAssertFalse(outcome.isFailure)
    }

    func testWithoutAHostImporterDropsAreRefusedUpFront() async {
        let viewModel = TranscriptViewModel(files: [], playback: PlaybackSpy())
        XCTAssertFalse(viewModel.canImportFiles)
        await viewModel.importFiles(at: [URL(fileURLWithPath: "/tmp/a.wav")])
        XCTAssertNil(viewModel.importMessage)
    }
}

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

@MainActor
private final class ClipboardSpy: TranscriptClipboardWriting {
    private(set) var text: String?

    func write(_ text: String) -> Bool {
        self.text = text
        return true
    }
}

private final class ImporterSpy: TranscriptFileImporting, @unchecked Sendable {
    var outcome = TranscriptImportOutcome(queuedCount: 0)
    private(set) var imported: [[URL]] = []

    func importFiles(at urls: [URL]) async -> TranscriptImportOutcome {
        imported.append(urls)
        return outcome
    }
}

private final class DeleterSpy: TranscriptFileDeleting, @unchecked Sendable {
    var error: (any Error)?
    private(set) var deleted: [TranscriptReviewFile.ID] = []

    func delete(fileID: TranscriptReviewFile.ID) throws {
        if let error { throw error }
        deleted.append(fileID)
    }
}

private final class ReprocessorSpy: TranscriptReprocessing, @unchecked Sendable {
    private(set) var requests: [(TranscriptReviewFile.ID, TranscriptionSpeakerCount)] = []
    var queuedRunID: String? = "queued-run"

    func reprocess(fileID: TranscriptReviewFile.ID, speakerCount: TranscriptionSpeakerCount) async -> TranscriptReprocessingOutcome {
        requests.append((fileID, speakerCount))
        return TranscriptReprocessingOutcome(message: "Queued a new run.", isFailure: false, queuedRunID: queuedRunID)
    }
}

private final class RetranscriberSpy: TranscriptRetranscribing, @unchecked Sendable {
    private(set) var fileIDs: [TranscriptReviewFile.ID] = []

    func retranscribe(fileID: TranscriptReviewFile.ID) async -> TranscriptReprocessingOutcome {
        fileIDs.append(fileID)
        return TranscriptReprocessingOutcome(message: "Queued a new transcription.", isFailure: false)
    }
}

private struct StubExportWriter: TranscriptExportWriting {
    let outcomes: [TranscriptExportOutcome]

    func write(
        _: CanonicalTranscript,
        formats _: Set<TranscriptExportFormat>,
        to _: URL,
        basename _: String
    ) -> [TranscriptExportOutcome] { outcomes }

    func write(
        _: CanonicalTranscript,
        format: TranscriptExportFormat,
        toFile fileURL: URL
    ) -> TranscriptExportOutcome {
        outcomes.first { $0.format == format }
            ?? TranscriptExportOutcome(format: format, destinationURL: fileURL, errorMessage: nil)
    }
}
