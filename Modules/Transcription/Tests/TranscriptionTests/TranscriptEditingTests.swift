import Foundation
import Speakers
import XCTest
@testable import Transcription

/// Renaming, splitting, combining, correcting words, moving turns between
/// speakers, undo, search, and the play head — the review edits beyond naming.
@MainActor
final class TranscriptEditingTests: XCTestCase {
    // MARK: - Naming

    func testRenamingIsASavedRevisionThatTheSidebarAndExportsUse() throws {
        let original = try fixture(named: "two-speakers")
        let store = RevisionStoreSpy()
        let viewModel = makeViewModel(transcript: original, revisionStore: store)
        XCTAssertEqual(viewModel.selectedFile?.displayName, "interview.m4a")

        viewModel.rename(to: "  Launch planning  ")

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.title, "Launch planning")
        XCTAssertEqual(revised.revision, original.revision + 1)
        XCTAssertEqual(viewModel.selectedFile?.displayName, "Launch planning")
        XCTAssertEqual(viewModel.selectedFile?.filename, "interview.m4a", "the source keeps its own name")
        XCTAssertEqual(store.saved.map(\.title), ["Launch planning"])
        XCTAssertEqual(FileTranscriptExportWriter.basename(for: revised), "Launch planning")
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))

        // The title round-trips through the canonical codec and the JSON export.
        let decoded = try CanonicalTranscriptCodec.decode(try CanonicalTranscriptCodec.encode(revised))
        XCTAssertEqual(decoded.title, "Launch planning")
        XCTAssertTrue(try TranscriptExporter.json(revised).contains("\"title\": \"Launch planning\""))

        viewModel.rename(to: nil)
        XCTAssertNil(viewModel.selectedTranscript?.title)
        XCTAssertEqual(viewModel.selectedFile?.displayName, "interview.m4a")
    }

    func testABlankNameIsRefusedWithoutMakingARevision() throws {
        let original = try fixture(named: "two-speakers")
        let viewModel = makeViewModel(transcript: original)

        viewModel.rename(to: "   ")

        XCTAssertEqual(viewModel.selectedTranscript?.revision, original.revision)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
    }

    func testExportBasenameDropsPathSeparators() throws {
        let transcript = try fixture(named: "two-speakers")
        let renamed = try TranscriptSegmentEditor.renaming(to: "Q3: a/b review", in: transcript)
        XCTAssertEqual(FileTranscriptExportWriter.basename(for: renamed), "Q3- a-b review")
        XCTAssertEqual(FileTranscriptExportWriter.basename(for: transcript), "interview")
    }

    // MARK: - Splitting

    func testSplittingAWordTimedTurnKeepsTheRecognizersTiming() throws {
        let original = try fixture(named: "one-speaker")
        let viewModel = makeViewModel(transcript: original)
        let segment = try XCTUnwrap(viewModel.chronologicalSegments.first)
        let tokens = viewModel.splitTokens(for: segment)
        XCTAssertEqual(tokens.map(\.text), ["Welcome", "to", "the", "meeting."])
        XCTAssertTrue(tokens.allSatisfy(\.isTimed))

        viewModel.split(segmentID: segment.id, beforeToken: 2)

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))
        let halves = revised.segments
        XCTAssertEqual(halves.map(\.text), ["Welcome to", "the meeting."])
        XCTAssertEqual(halves.map(\.id), ["segment_001.1", "segment_001.2"])
        XCTAssertEqual(halves[0].startMs, segment.startMs)
        XCTAssertEqual(halves[0].endMs, 2_000, "the first half ends where its last word ends")
        XCTAssertEqual(halves[1].startMs, 2_050, "the second half starts where its first word starts")
        XCTAssertEqual(halves[1].endMs, segment.endMs)
        XCTAssertEqual(halves.map(\.timingQuality), [.asrWord, .asrWord])
        XCTAssertEqual(halves.map { $0.words?.count }, [2, 2])
        XCTAssertEqual(halves.map(\.speakerID), [segment.speakerID, segment.speakerID])
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_001.1", "the earlier half stays selected")
        XCTAssertNil(revised.subtitleCueMappings, "cues that named the old segment are rebuilt on export")
        XCTAssertNoThrow(try TranscriptExporter.export(revised, as: .subtitles))
    }

    func testSplittingWithoutWordTimingsEstimatesTheBoundaryAndSaysSo() throws {
        let original = try fixture(named: "two-speakers")
        let viewModel = makeViewModel(transcript: original)
        let segment = try XCTUnwrap(viewModel.chronologicalSegments.last) // "Yes, I have the notes." 3300–6000
        let tokens = viewModel.splitTokens(for: segment)
        XCTAssertEqual(tokens.map(\.text), ["Yes,", "I", "have", "the", "notes."])
        XCTAssertFalse(tokens[0].isTimed)
        XCTAssertEqual(tokens.first?.startMs, 3_300)
        XCTAssertEqual(tokens.last?.endMs, 6_000)

        viewModel.split(segmentID: segment.id, beforeToken: 1)

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))
        let halves = revised.segments.filter { $0.id.hasPrefix("segment_002.") }
        XCTAssertEqual(halves.map(\.text), ["Yes,", "I have the notes."])
        XCTAssertEqual(halves[0].startMs, 3_300)
        XCTAssertEqual(halves[0].endMs, halves[1].startMs, "an estimated boundary leaves no gap")
        XCTAssertLessThan(halves[0].endMs, 6_000)
        XCTAssertEqual(halves[1].endMs, 6_000)
        XCTAssertEqual(halves.map(\.timingQuality), [.segmentOnly, .segmentOnly])
        XCTAssertTrue(try TranscriptExporter.plainText(revised).contains("[timing approximate] Speaker 2: Yes,"))
    }

    func testSplittingOutsideTheWordsIsRefused() throws {
        let transcript = try fixture(named: "one-speaker")
        XCTAssertThrowsError(try TranscriptSegmentEditor.splitting(segmentID: "segment_001", beforeToken: 0, in: transcript))
        XCTAssertThrowsError(try TranscriptSegmentEditor.splitting(segmentID: "segment_001", beforeToken: 4, in: transcript))
        XCTAssertThrowsError(try TranscriptSegmentEditor.splitting(segmentID: "nope", beforeToken: 1, in: transcript))
    }

    func testSplittingTheSameTurnTwiceNeverReusesAnID() throws {
        let transcript = try fixture(named: "split-long-turn")
        let once = try TranscriptSegmentEditor.splitting(segmentID: "segment_001", beforeToken: 5, in: transcript)
        let twice = try TranscriptSegmentEditor.splitting(segmentID: "segment_001.2", beforeToken: 3, in: once)
        XCTAssertEqual(Set(twice.segments.map(\.id)).count, twice.segments.count)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(twice))
    }

    // MARK: - Combining

    func testCombiningNeighboursJoinsWordsAndSpansBothTurns() throws {
        let original = try fixture(named: "two-speakers")
        let viewModel = makeViewModel(transcript: original)

        viewModel.merge(segmentID: "segment_002", withNext: false)

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))
        XCTAssertEqual(revised.segments.count, 1)
        let merged = try XCTUnwrap(revised.segments.first)
        XCTAssertEqual(merged.id, "segment_001")
        XCTAssertEqual(merged.text, "Can we begin? Yes, I have the notes.")
        XCTAssertEqual(merged.startMs, 500)
        XCTAssertEqual(merged.endMs, 6_000)
        XCTAssertEqual(merged.speakerLabel, "Alex", "the earlier turn's speaker is kept")
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_001")
        XCTAssertTrue(viewModel.speakerActionMessage?.text.contains("reassign") == true, "the message says the speakers disagreed")
    }

    func testCombiningKeepsWordTimingsWhenBothHalvesHadThem() throws {
        let transcript = try fixture(named: "one-speaker")
        let split = try TranscriptSegmentEditor.splitting(segmentID: "segment_001", beforeToken: 2, in: transcript)
        let rejoined = try TranscriptSegmentEditor.merging(segmentID: "segment_001.1", with: "segment_001.2", in: split)

        let merged = try XCTUnwrap(rejoined.segments.first)
        XCTAssertEqual(merged.text, "Welcome to the meeting.")
        XCTAssertEqual(merged.words?.map(\.text), ["Welcome", "to", "the", "meeting."])
        XCTAssertEqual(merged.timingQuality, .asrWord)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(rejoined))
    }

    func testOnlyNeighbouringTurnsCombine() throws {
        let transcript = try fixture(named: "four-speakers")
        XCTAssertThrowsError(try TranscriptSegmentEditor.merging(segmentID: "segment_001", with: "segment_003", in: transcript))
        let viewModel = makeViewModel(transcript: transcript)
        viewModel.merge(segmentID: "segment_001", withNext: false)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
        XCTAssertEqual(viewModel.selectedTranscript?.revision, transcript.revision)
    }

    // MARK: - Words

    func testCorrectingWordsDropsTheirTimingsButKeepsTheTurn() throws {
        let original = try fixture(named: "one-speaker")
        let viewModel = makeViewModel(transcript: original)

        viewModel.replaceText(of: "segment_001", with: "Welcome to the weekly meeting.\n")

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        let segment = try XCTUnwrap(revised.segments.first)
        XCTAssertEqual(segment.text, "Welcome to the weekly meeting.")
        XCTAssertNil(segment.words)
        XCTAssertEqual(segment.startMs, 1_000)
        XCTAssertEqual(segment.endMs, 4_200)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))

        viewModel.replaceText(of: "segment_001", with: "   ")
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
        XCTAssertEqual(viewModel.selectedTranscript?.segments.first?.text, "Welcome to the weekly meeting.")

        let before = viewModel.selectedTranscript?.revision
        viewModel.replaceText(of: "segment_001", with: "Welcome to the weekly meeting.")
        XCTAssertEqual(viewModel.selectedTranscript?.revision, before, "unchanged words are not a revision")
    }

    // MARK: - Speakers

    func testMovingATurnToAnotherRecordingSpeakerNeedsNoSavedPerson() throws {
        let original = try fixture(named: "four-speakers")
        let viewModel = makeViewModel(transcript: original)

        viewModel.move(segmentID: "segment_002", toSpeakerID: "speaker_1")

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        let moved = try XCTUnwrap(revised.segments.first { $0.id == "segment_002" })
        XCTAssertEqual(moved.speakerID, "speaker_1")
        XCTAssertEqual(moved.speakerLabel, "Speaker 1")
        XCTAssertEqual(revised.speakers.count, original.speakers.count, "an emptied speaker stays until merged")
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))
        XCTAssertEqual(viewModel.speakerActionMessage?.text, "Moved this turn to Speaker 1.")
    }

    func testMergingOneSpeakerIntoAnotherRelabelsEveryTurnAndDropsTheEntry() throws {
        let original = try fixture(named: "four-speakers")
        let viewModel = makeViewModel(transcript: original)
        viewModel.speakerFilterID = "speaker_2"

        viewModel.mergeSpeaker("speaker_2", into: "speaker_3")

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.speakers.map(\.id), ["speaker_1", "speaker_3", "speaker_4"])
        XCTAssertEqual(revised.segments.first { $0.id == "segment_002" }?.speakerLabel, "Sam")
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_3" }?.identityAssignment, .automatic, "the target keeps its own assignment")
        XCTAssertEqual(viewModel.speakerFilterID, "speaker_3", "a filter on the merged speaker follows it")
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))
        XCTAssertEqual(viewModel.speakerActionMessage?.text, "Merged Speaker 2 into Sam.")

        XCTAssertThrowsError(try TranscriptSpeakerLabelEditor.merging(speakerID: "speaker_1", into: "speaker_1", in: revised))
    }

    // MARK: - Undo

    func testUndoAndRedoWalkTheEditsAsNewSavedRevisions() throws {
        let original = try fixture(named: "two-speakers")
        let store = RevisionStoreSpy()
        let viewModel = makeViewModel(transcript: original, revisionStore: store)
        XCTAssertFalse(viewModel.canUndo)

        viewModel.rename(to: "First")
        viewModel.merge(segmentID: "segment_001", withNext: true)
        XCTAssertTrue(viewModel.canUndo)
        XCTAssertFalse(viewModel.canRedo)

        viewModel.undo()
        XCTAssertEqual(viewModel.selectedTranscript?.segments.count, 2)
        XCTAssertEqual(viewModel.selectedTranscript?.title, "First")
        XCTAssertEqual(viewModel.selectedTranscript?.revision, original.revision + 3, "undo is a newer revision, never a rewind")
        XCTAssertTrue(viewModel.canRedo)

        viewModel.undo()
        XCTAssertNil(viewModel.selectedTranscript?.title)
        XCTAssertFalse(viewModel.canUndo)

        viewModel.redo()
        XCTAssertEqual(viewModel.selectedTranscript?.title, "First")
        viewModel.redo()
        XCTAssertEqual(viewModel.selectedTranscript?.segments.count, 1)
        XCTAssertFalse(viewModel.canRedo)

        viewModel.undo()
        viewModel.rename(to: "Branch")
        XCTAssertFalse(viewModel.canRedo, "a fresh edit discards the redo branch")
        XCTAssertEqual(store.saved.map(\.revision), Array((original.revision + 1)...(original.revision + 8)), "every step, undo included, was saved")
    }

    func testAFailedEditLeavesUndoUntouched() throws {
        let viewModel = makeViewModel(transcript: try fixture(named: "two-speakers"))
        viewModel.replaceText(of: "missing", with: "words")
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
        XCTAssertFalse(viewModel.canUndo)
    }

    // MARK: - Search and filters

    func testSearchMatchesWordsAndSpeakersIgnoringCaseAndAccents() throws {
        let viewModel = makeViewModel(transcript: try fixture(named: "two-speakers"))
        XCTAssertFalse(viewModel.isFiltering)

        viewModel.searchText = "NOTES"
        XCTAssertEqual(viewModel.visibleSegments.map(\.id), ["segment_002"])
        XCTAssertTrue(viewModel.isFiltering)

        viewModel.searchText = "álex"
        XCTAssertEqual(viewModel.visibleSegments.map(\.id), ["segment_001"], "the speaker's name is searchable too")

        viewModel.searchText = " "
        XCTAssertEqual(viewModel.visibleSegments.count, 2)
        XCTAssertFalse(viewModel.isFiltering)
    }

    func testSpeakerAndReviewFiltersNarrowTheListWithoutChangingPlaybackOrder() throws {
        let viewModel = makeViewModel(transcript: try fixture(named: "unknown-speaker"))
        let total = viewModel.chronologicalSegments.count
        XCTAssertGreaterThan(viewModel.segmentsNeedingReviewCount, 0)

        viewModel.reviewFilter = .unknownSpeaker
        XCTAssertTrue(viewModel.visibleSegments.allSatisfy { $0.speakerID == nil })
        XCTAssertEqual(viewModel.chronologicalSegments.count, total, "playback still walks every turn")

        let crowded = makeViewModel(transcript: try fixture(named: "four-speakers"))
        crowded.speakerFilterID = "speaker_3"
        XCTAssertEqual(crowded.visibleSegments.map(\.id), ["segment_003"])
        XCTAssertTrue(crowded.isFiltering)
        crowded.speakerFilterID = nil
        XCTAssertEqual(crowded.visibleSegments.count, 4)
    }

    func testJumpingToTheNextTurnNeedingReviewWraps() throws {
        let viewModel = makeViewModel(transcript: try fixture(named: "dense-overlap"))
        let flagged = viewModel.chronologicalSegments.filter(\.needsReview).map(\.id)
        XCTAssertGreaterThan(flagged.count, 1)

        XCTAssertTrue(viewModel.selectNextSegmentNeedingReview())
        XCTAssertEqual(viewModel.selectedSegmentID, flagged[0])
        for expected in flagged.dropFirst() {
            viewModel.selectNextSegmentNeedingReview()
            XCTAssertEqual(viewModel.selectedSegmentID, expected)
        }
        viewModel.selectNextSegmentNeedingReview()
        XCTAssertEqual(viewModel.selectedSegmentID, flagged[0], "wraps to the first flagged turn")

        let clean = makeViewModel(transcript: try fixture(named: "one-speaker"))
        XCTAssertFalse(clean.selectNextSegmentNeedingReview())
    }

    // MARK: - Play head

    func testScrubbingMovesThePlayHeadAndTheSelectionWithoutStartingSound() throws {
        let playback = PlaybackSpy()
        let viewModel = makeViewModel(transcript: try fixture(named: "two-speakers"), playback: playback)

        viewModel.seek(toMilliseconds: 4_000)
        XCTAssertEqual(viewModel.playheadMilliseconds, 4_000)
        XCTAssertEqual(playback.soughtMilliseconds, [4_000])
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_002")
        XCTAssertNil(viewModel.playbackStatus)
        XCTAssertTrue(playback.transport.isEmpty)

        viewModel.skip(byMilliseconds: -10_000)
        XCTAssertEqual(viewModel.playheadMilliseconds, 0, "clamped to the start")
        viewModel.skip(byMilliseconds: 99_000)
        XCTAssertEqual(viewModel.playheadMilliseconds, 20_000, "clamped to the source length")

        viewModel.playSelectedOrToggle()
        XCTAssertEqual(viewModel.playingSegmentID, "segment_002")
        XCTAssertEqual(playback.transport, [.play])
        viewModel.seek(toMilliseconds: 600)
        XCTAssertEqual(viewModel.playingSegmentID, "segment_001", "while playing the readout follows the play head")
        playback.emit(.timeChanged(milliseconds: 700))
        XCTAssertEqual(viewModel.playheadMilliseconds, 700)
    }

    func testArrowNavigationWalksTheVisibleTurnsAndFollowsWhilePlaying() throws {
        let playback = PlaybackSpy()
        let viewModel = makeViewModel(transcript: try fixture(named: "four-speakers"), playback: playback)

        viewModel.selectNeighbouringSegment(offset: 1)
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_001")
        viewModel.selectNeighbouringSegment(offset: 1)
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_002")
        viewModel.selectNeighbouringSegment(offset: -5)
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_001")
        XCTAssertTrue(playback.transport.isEmpty, "browsing is silent")

        viewModel.speakerFilterID = "speaker_4"
        viewModel.selectNeighbouringSegment(offset: 1)
        XCTAssertEqual(viewModel.selectedSegmentID, "segment_004", "navigation stays within the filtered list")

        viewModel.speakerFilterID = nil
        viewModel.playSelectedOrToggle()
        viewModel.selectNeighbouringSegment(offset: -1)
        XCTAssertEqual(viewModel.playingSegmentID, "segment_003", "while playing the audio moves too")
        XCTAssertEqual(playback.transport, [.play, .play])
    }

    func testPlaybackRateIsHandedToThePlayer() throws {
        let playback = PlaybackSpy()
        let viewModel = makeViewModel(transcript: try fixture(named: "two-speakers"), playback: playback)
        viewModel.setPlaybackRate(1.5)
        XCTAssertEqual(viewModel.playbackRate, 1.5)
        XCTAssertEqual(playback.rates, [1.5])
    }

    // MARK: - Helpers

    private func makeViewModel(
        transcript: CanonicalTranscript,
        playback: PlaybackSpy = PlaybackSpy(),
        revisionStore: RevisionStoreSpy? = nil
    ) -> TranscriptViewModel {
        TranscriptViewModel(
            files: [
                TranscriptReviewFile(
                    sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-editing-snapshot.flac"),
                    transcript: transcript,
                    jobState: .complete
                )
            ],
            playback: playback,
            revisionStore: revisionStore
        )
    }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

@MainActor
private final class PlaybackSpy: TranscriptPlaybackSeeking {
    enum Transport: Equatable { case play, pause }

    private(set) var soughtMilliseconds: [Int] = []
    private(set) var transport: [Transport] = []
    private(set) var rates: [Float] = []
    private var observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?

    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds milliseconds: Int) { soughtMilliseconds.append(milliseconds) }
    func play() { transport.append(.play) }
    func pause() { transport.append(.pause) }
    func setRate(_ rate: Float) { rates.append(rate) }
    func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?) { self.observer = observer }

    func emit(_ event: TranscriptPlaybackEvent) { observer?(event) }
}

private final class RevisionStoreSpy: TranscriptRevisionStoring, @unchecked Sendable {
    private(set) var saved: [CanonicalTranscript] = []

    func save(_ transcript: CanonicalTranscript, forFileID _: TranscriptReviewFile.ID) throws {
        saved.append(transcript)
    }
}
