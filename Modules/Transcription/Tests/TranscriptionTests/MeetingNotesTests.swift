import AppKit
import AVFoundation
import Foundation
import ScribeAppCore
@testable import Transcription
import XCTest

// MARK: - Grouping and stamp rules

final class MeetingNotesTextTests: XCTestCase {
    func testABlankLineSeparatesNotesAndReturnStaysInTheSameNote() {
        let text = "First line\nsecond line\n\nNext note\n   \nThird\n\n"
        let ranges = MeetingNotesText.groupRanges(in: text)
        let string = text as NSString
        XCTAssertEqual(ranges.map(string.substring(with:)), ["First line\nsecond line", "Next note", "Third"],
                       "a whitespace-only line is blank, and trailing blank lines end nothing")
        XCTAssertEqual(MeetingNotesText.groupRanges(in: ""), [])
        XCTAssertEqual(MeetingNotesText.groupRanges(in: "\n\n\n"), [])
    }

    func testANewNoteTakesTheClockAndAnExtendedNoteKeepsItsStamp() {
        let existing = MeetingNoteTag(recordingOffsetMilliseconds: 1_000)
        var reads = 0
        let tags = MeetingNotesText.resolve([
            .init(range: NSRange(location: 0, length: 4), tags: [existing], hasUntaggedText: true),
            .init(range: NSRange(location: 6, length: 1), tags: [], hasUntaggedText: true),
        ]) {
            reads += 1
            return 9_000
        }
        XCTAssertEqual(tags[0], existing, "typing into a note keeps its stamp")
        XCTAssertEqual(tags[1].recordingOffsetMilliseconds, 9_000, "the first character of a new note is stamped")
        XCTAssertEqual(reads, 1, "the clock is read only for the new note")
    }

    func testJoiningKeepsTheEarlierStampAndATimedOneOverUntimed() {
        let early = MeetingNoteTag(recordingOffsetMilliseconds: 2_000)
        let late = MeetingNoteTag(recordingOffsetMilliseconds: 5_000)
        let untimed = MeetingNoteTag(recordingOffsetMilliseconds: nil)
        XCTAssertEqual(MeetingNotesText.resolve([.init(range: NSRange(), tags: [late, early])], clock: { 0 }), [early])
        XCTAssertEqual(MeetingNotesText.resolve([.init(range: NSRange(), tags: [untimed, late])], clock: { 0 }), [late])
        let both = MeetingNoteTag(recordingOffsetMilliseconds: nil)
        XCTAssertEqual(MeetingNotesText.resolve([.init(range: NSRange(), tags: [untimed, both])], clock: { 0 }), [untimed])
    }

    func testSplittingGivesBothHalvesTheOriginalStamp() {
        let original = MeetingNoteTag(recordingOffsetMilliseconds: 3_000)
        let tags = MeetingNotesText.resolve([
            .init(range: NSRange(), tags: [original]),
            .init(range: NSRange(), tags: [original]),
        ], clock: { XCTFail("a split is not a new note"); return 0 })
        XCTAssertEqual(tags[0], original)
        XCTAssertNotEqual(tags[1].id, original.id, "the second half becomes its own note")
        XCTAssertEqual(tags[1].recordingOffsetMilliseconds, 3_000)
    }

    func testNotesRoundTripThroughTheirText() {
        let notes = [
            MeetingNote(text: "Budget\nis late", recordingOffsetMilliseconds: 12_000),
            MeetingNote(text: "Ask Dana", recordingOffsetMilliseconds: nil),
        ]
        let text = MeetingNotesText.text(for: notes)
        XCTAssertEqual(text, "Budget\nis late\n\nAsk Dana")
        let ranges = MeetingNotesText.groupRanges(in: text)
        XCTAssertEqual(ranges, MeetingNotesText.ranges(for: notes))
        let tags = notes.map { MeetingNoteTag(id: $0.id, recordingOffsetMilliseconds: $0.recordingOffsetMilliseconds) }
        XCTAssertEqual(MeetingNotesText.notes(in: text, ranges: ranges, tags: tags), notes)
    }

    func testStampsReadAsTimesAndSpeakAsWords() {
        XCTAssertEqual(MeetingNotesText.stampText(350_000), "05:50")
        XCTAssertEqual(MeetingNotesText.stampText(3_723_000), "1:02:03", "long recordings show hours")
        XCTAssertEqual(MeetingNotesText.stampText(nil), "--:--")
        XCTAssertEqual(MeetingNotesText.accessibilityLabel(350_000), "Note at 5 minutes, 50 seconds")
        XCTAssertEqual(MeetingNotesText.accessibilityLabel(400), "Note at 0 seconds")
        XCTAssertEqual(MeetingNotesText.accessibilityLabel(nil), "Note without a recording time")
    }
}

// MARK: - Sidecar

final class MeetingNotesSidecarTests: XCTestCase {
    private var meeting: URL!

    override func setUpWithError() throws {
        meeting = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Sidecar \(UUID().uuidString)/meeting--abc", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: meeting.deletingLastPathComponent())
    }

    func testTheSidecarIsVersionedOwnerOnlyAndHoldsOnlyNotes() throws {
        let draft = UUID(), session = UUID()
        var sidecar = MeetingNotesSidecar()
        sidecar.setNotes([MeetingNote(text: "Decision: ship", recordingOffsetMilliseconds: 61_000)], shownBy: draft, recorderSessionID: session, revision: 4)
        try MeetingNotesSidecarFile.write(sidecar, meetingDirectory: meeting)

        let url = MeetingNotesSidecarFile.url(inMeeting: meeting)
        XCTAssertEqual(url.lastPathComponent, "meeting-notes.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        for privateField in ["prompt", "mcpURL", "agentID", "handoff", "send"] {
            XCTAssertFalse(text.contains(privateField), "\(privateField) must never be written beside the transcript")
        }
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: meeting), sidecar)
        XCTAssertEqual(sidecar.entry(forDraft: draft)?.attachedRevision, 4)
    }

    func testAWriteNeverRecreatesADeletedMeeting() throws {
        try FileManager.default.removeItem(at: meeting)
        XCTAssertThrowsError(try MeetingNotesSidecarFile.write(MeetingNotesSidecar(), meetingDirectory: meeting)) {
            XCTAssertEqual($0 as? MeetingNotesSidecarFile.FileError, .meetingMissing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.path))
    }

    func testAnUnreadableSidecarIsReportedNotReplaced() throws {
        let url = MeetingNotesSidecarFile.url(inMeeting: meeting)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try MeetingNotesSidecarFile.read(meetingDirectory: meeting))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }

    func testTwoDraftsSharingAMeetingKeepSeparateEntries() {
        let first = UUID(), second = UUID()
        var sidecar = MeetingNotesSidecar()
        sidecar.setNotes([MeetingNote(text: "mine")], shownBy: first, recorderSessionID: UUID(), revision: 1)
        sidecar.setNotes([MeetingNote(text: "theirs")], shownBy: second, recorderSessionID: UUID(), revision: 1)
        sidecar.setNotes([MeetingNote(text: "mine, edited")], shownBy: first, recorderSessionID: UUID(), revision: 2)
        XCTAssertEqual(sidecar.notes(shownBy: first).map(\.text), ["mine, edited"])
        XCTAssertEqual(sidecar.notes(shownBy: second).map(\.text), ["theirs"])
    }

    func testCombinedEntriesStayContiguousAndKeepTheirSourceDraft() {
        let owner = UUID(), absorbed = UUID()
        let a = MeetingNote(text: "a", recordingOffsetMilliseconds: 1_000)
        let c = MeetingNote(text: "c", recordingOffsetMilliseconds: 9_000)
        var sidecar = MeetingNotesSidecar(entries: [
            MeetingNotesEntry(draftID: owner, recorderSessionID: UUID(), attachedRevision: 1, notes: [a]),
            MeetingNotesEntry(draftID: absorbed, recorderSessionID: UUID(), attachedRevision: 1, ownerDraftID: owner, notes: [c]),
        ])
        XCTAssertEqual(sidecar.notes(shownBy: owner), [a, c])
        XCTAssertEqual(sidecar.notes(shownBy: absorbed), [], "the absorbed draft's row is gone; its notes show on the owner's")

        // A note added after `c` joins `c`'s entry; one added first joins the owner's.
        let top = MeetingNote(text: "top"), tail = MeetingNote(text: "tail")
        sidecar.setNotes([top, a, c, tail], shownBy: owner, recorderSessionID: UUID(), revision: 2)
        XCTAssertEqual(sidecar.entry(forDraft: owner)?.notes, [top, a])
        XCTAssertEqual(sidecar.entry(forDraft: absorbed)?.notes, [c, tail])
        XCTAssertEqual(sidecar.notes(shownBy: owner), [top, a, c, tail])
    }

    func testShiftingMovesTimedNotesAndKeepsUntimedOnesUntimed() {
        let sidecar = MeetingNotesSidecar(entries: [
            MeetingNotesEntry(draftID: UUID(), recorderSessionID: UUID(), attachedRevision: 1, notes: [
                MeetingNote(text: "timed", recordingOffsetMilliseconds: 500),
                MeetingNote(text: "untimed", recordingOffsetMilliseconds: nil),
            ]),
        ])
        let shifted = sidecar.shifted(byMilliseconds: 4_000).entries[0].notes
        XCTAssertEqual(shifted.map(\.recordingOffsetMilliseconds), [4_500, nil])
        XCTAssertEqual(shifted.map(\.id), sidecar.entries[0].notes.map(\.id))
    }
}

// MARK: - Editor

@MainActor
final class MeetingNotesEditorTests: XCTestCase {
    private var clockValue: Int? = 0
    private var clockReads = 0
    private var reported: [[MeetingNote]] = []
    private var seekable = false
    private var focus: [Bool] = []
    private var window: NSWindow!

    override func setUp() async throws {
        _ = NSApplication.shared
        clockValue = 0
        clockReads = 0
        reported = []
        seekable = false
        focus = []
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    func testTypingStampsTheFirstCharacterAndReturnStaysInTheNote() {
        let view = makeEditor()
        clockValue = 5_000
        type("H", in: view)
        clockValue = 9_000
        type("ello\nworld", in: view)
        XCTAssertEqual(notes(view).map(\.text), ["Hello\nworld"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [5_000])
        XCTAssertEqual(clockReads, 1, "only the first character of a note reads the clock")

        clockValue = 12_000
        type("\n\nNext", in: view)
        XCTAssertEqual(notes(view).map(\.text), ["Hello\nworld", "Next"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [5_000, 12_000])
        XCTAssertEqual(reported.last, notes(view))
    }

    func testANoteWrittenWhilePausedOrStoppedIsUntimed() {
        let view = makeEditor()
        clockValue = nil
        type("No time", in: view)
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [nil])
        XCTAssertEqual(view.visibleStamps.map(\.text), ["--:--"])
        XCTAssertEqual(view.visibleStamps.map(\.label), ["Note without a recording time"])
    }

    func testSplittingAndJoiningNotesInTheEditor() {
        let first = MeetingNote(text: "one two", recordingOffsetMilliseconds: 1_000)
        let second = MeetingNote(text: "three", recordingOffsetMilliseconds: 4_000)
        let view = makeEditor(notes: [first, second])
        clockValue = 99_000

        // Split "one two" with a blank line.
        view.textView.setSelectedRange(NSRange(location: 3, length: 1))
        type("\n\n", in: view)
        XCTAssertEqual(notes(view).map(\.text), ["one", "two", "three"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [1_000, 1_000, 4_000])
        XCTAssertEqual(notes(view)[0].id, first.id)
        XCTAssertNotEqual(notes(view)[1].id, first.id)

        // Join "two" and "three" by replacing the blank line with a space.
        let text = view.textView.string as NSString
        let gap = text.range(of: "\n\nthree")
        type(" ", in: view, replacing: NSRange(location: gap.location, length: 2))
        XCTAssertEqual(notes(view).map(\.text), ["one", "two three"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [1_000, 1_000], "a join keeps the earlier stamp")
        XCTAssertEqual(clockReads, 0, "splitting and joining never stamp a new time")
    }

    func testPastingSeveralNotesGivesEachThePasteTime() {
        let view = makeEditor(notes: [MeetingNote(text: "before", recordingOffsetMilliseconds: 1_000)])
        clockValue = 20_000
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("scribe-notes-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("\n\nalpha\nmore\n\nbeta", forType: .string)
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
        XCTAssertTrue(view.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(notes(view).map(\.text), ["before", "alpha\nmore", "beta"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [1_000, 20_000, 20_000])
        XCTAssertEqual(clockReads, 1, "one paste is one moment")
    }

    func testUndoAndRedoRestoreNotesWithTheirStamps() throws {
        let keep = MeetingNote(text: "keep", recordingOffsetMilliseconds: 1_000)
        let gone = MeetingNote(text: "gone", recordingOffsetMilliseconds: 3_000)
        let view = makeEditor(notes: [keep, gone])
        let undo = try XCTUnwrap(view.textView.undoManager)
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        view.textView.setSelectedRange(NSRange(location: 4, length: 6))
        view.textView.delete(nil)
        undo.endUndoGrouping()
        XCTAssertEqual(notes(view), [keep])

        undo.undo()
        XCTAssertEqual(notes(view), [keep, gone], "the deleted note comes back with its identity and time")
        undo.redo()
        XCTAssertEqual(notes(view), [keep])

        clockValue = 7_000
        undo.beginUndoGrouping()
        type("\n\nnew", in: view)
        undo.endUndoGrouping()
        let added = try XCTUnwrap(notes(view).last)
        XCTAssertEqual(added.recordingOffsetMilliseconds, 7_000)
        undo.undo()
        XCTAssertEqual(notes(view), [keep])
        clockValue = 50_000
        undo.redo()
        XCTAssertEqual(notes(view).last, added, "redo brings back the stamp it was typed with, not the clock now")
    }

    func testMarkedTextStartsNoNoteUntilItIsCommitted() {
        let view = makeEditor()
        clockValue = 8_000
        view.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.textView.hasMarkedText())
        XCTAssertEqual(reported, [], "composition is not a note")
        XCTAssertEqual(clockReads, 0)
        view.textView.insertText("火", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.textView.hasMarkedText())
        XCTAssertEqual(notes(view).map(\.text), ["火"])
        XCTAssertEqual(notes(view).map(\.recordingOffsetMilliseconds), [8_000])
        XCTAssertEqual(clockReads, 1)
    }

    func testTheClockTickingNeverReplacesTheTextOrMovesTheCaret() throws {
        let draftID = UUID()
        let view = makeEditor(draftID: draftID)
        clockValue = 1_000
        type("Typing here", in: view)
        view.textView.setSelectedRange(NSRange(location: 3, length: 2))
        let undo = try XCTUnwrap(view.textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        let storage = view.textView.textStorage
        for tick in 0 ..< 10 {
            // What SwiftUI does every second while the status line ticks:
            // the same notes back, with fresh closures.
            clockValue = 1_000 + tick * 1_000
            view.configure(with: editor(draftID: draftID, notes: notes(view)))
        }
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 3, length: 2))
        XCTAssertTrue(view.textView.textStorage === storage)
        XCTAssertTrue(undo.canUndo, "replacing the text would have dropped the undo history")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(clockReads, 1)
    }

    func testAChangeMadeElsewhereReplacesTheTextAndKeepsTheCaretInRange() {
        let draftID = UUID()
        let view = makeEditor(draftID: draftID, notes: [MeetingNote(text: "a long first note")])
        view.textView.setSelectedRange(NSRange(location: 10, length: 0))
        view.configure(with: editor(draftID: draftID, notes: [MeetingNote(text: "short")]))
        XCTAssertEqual(view.textView.string, "short")
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertEqual(reported, [], "loading is not an edit")
    }

    func testStampsAreAccessibleButtonsThatSeekOnlyWhenPlaybackCan() throws {
        let note = MeetingNote(text: "Pricing", recordingOffsetMilliseconds: 350_000)
        var seeks: [Int] = []
        let draftID = UUID()
        let view = makeEditor(draftID: draftID, notes: [note])
        XCTAssertEqual(view.visibleStamps.map(\.text), ["05:50"])
        XCTAssertEqual(view.visibleStamps.map(\.enabled), [false], "no seeking while the recording is not playable")
        XCTAssertEqual(view.visibleStamps.map(\.label), ["Note at 5 minutes, 50 seconds"])

        seekable = true
        view.configure(with: editor(draftID: draftID, notes: [note], onSeek: { seeks.append($0) }))
        XCTAssertEqual(view.visibleStamps.map(\.enabled), [true])
        let button = try XCTUnwrap(view.stampButtonsForTesting.first)
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(seeks, [350_000])
        XCTAssertTrue(view.textView.nextKeyView === button, "the stamps follow the notes in the key view loop")
    }

    func testFocusIsReportedSoTheWindowStandsItsShortcutsAside() {
        let view = makeEditor()
        window.makeFirstResponder(nil)
        XCTAssertEqual(focus.last, false)
        window.makeFirstResponder(view.textView)
        XCTAssertEqual(focus.last, true)
        view.dismantle()
        XCTAssertEqual(focus.last, false)
    }

    // MARK: Helpers

    private func makeEditor(draftID: UUID = UUID(), notes: [MeetingNote] = []) -> MeetingNotesEditorView {
        let view = MeetingNotesEditorView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.configure(with: editor(draftID: draftID, notes: notes))
        view.layoutSubtreeIfNeeded()
        view.layoutDocument()
        window.makeFirstResponder(view.textView)
        return view
    }

    private func editor(draftID: UUID, notes: [MeetingNote], onSeek: @escaping @MainActor (Int) -> Void = { _ in }) -> MeetingNotesEditor {
        MeetingNotesEditor(
            draftID: draftID,
            notes: notes,
            clock: { [unowned self] in
                clockReads += 1
                return clockValue
            },
            canSeek: { [unowned self] offset in seekable && offset != nil },
            onSeek: onSeek,
            onNotesChange: { [unowned self] id, notes in
                XCTAssertEqual(id, draftID, "every change names the draft it was made in")
                reported.append(notes)
            },
            onFocusChange: { [unowned self] in focus.append($0) }
        )
    }

    private func type(_ text: String, in view: MeetingNotesEditorView, replacing range: NSRange = NSRange(location: NSNotFound, length: 0)) {
        view.textView.insertText(text, replacementRange: range)
    }

    private func notes(_ view: MeetingNotesEditorView) -> [MeetingNote] { view.currentNotes }
}

// MARK: - Review: seeking and combining gates

@MainActor
final class MeetingNotesReviewTests: XCTestCase {
    func testAStampSeeksAndHighlightsTheNearestTurn() {
        let playback = RecordingPlayback()
        let file = draftFile(hasAudio: true)
        let model = TranscriptViewModel(files: [file], playback: playback)

        XCTAssertTrue(model.canSeek(toNoteOffset: 2_500, in: file))
        model.seek(toNoteOffset: 2_500)
        XCTAssertEqual(playback.seeks.last, 2_500)
        XCTAssertEqual(model.selectedSegmentID, "seg_2", "inside a turn: that turn")
        XCTAssertEqual(model.playheadMilliseconds, 2_500)

        model.seek(toNoteOffset: 4_300)
        XCTAssertEqual(model.selectedSegmentID, "seg_3", "between turns: the closest one")
        model.seek(toNoteOffset: 0)
        XCTAssertEqual(model.selectedSegmentID, "seg_1")
        XCTAssertFalse(model.isPlaying, "seeking to a note never starts sound")

        XCTAssertFalse(model.canSeek(toNoteOffset: 6_001, in: file), "past the end of the recording")
        XCTAssertFalse(model.canSeek(toNoteOffset: nil, in: file), "an untimed note")
        let seeks = playback.seeks.count
        model.seek(toNoteOffset: 9_000)
        XCTAssertEqual(playback.seeks.count, seeks)
    }

    func testStampsStopSeekingOnceTheAudioIsDeleted() {
        let file = draftFile(hasAudio: false)
        let model = TranscriptViewModel(files: [file], playback: RecordingPlayback())
        XCTAssertFalse(model.canSeek(toNoteOffset: 2_500, in: file))
    }

    func testNearestTurnPrefersTheTurnSpanningTheTime() {
        let segments = sampleSegments()
        XCTAssertEqual(TranscriptViewModel.nearestSegment(to: 500, in: segments)?.id, "seg_1")
        XCTAssertEqual(TranscriptViewModel.nearestSegment(to: 3_400, in: segments)?.id, "seg_2")
        XCTAssertEqual(TranscriptViewModel.nearestSegment(to: 60_000, in: segments)?.id, "seg_3")
        XCTAssertNil(TranscriptViewModel.nearestSegment(to: 0, in: []))
    }

    func testCombiningIsRefusedWhileASendIsUnderWay() {
        let blocked = draftFile(hasAudio: true, sendBlocksCombine: true)
        let free = draftFile(hasAudio: true)
        let model = TranscriptViewModel(files: [blocked, free], playback: RecordingPlayback(), recordingCombiner: NeverCombiner())
        XCTAssertFalse(model.canCombine(blocked))
        XCTAssertTrue(model.canCombine(free))
        XCTAssertEqual(model.combineCandidates(for: free).map(\.id), [])
    }

    func testImportsHaveNoNotesPane() {
        let imported = TranscriptReviewFile(id: "run", sourceSnapshotURL: URL(fileURLWithPath: "/tmp/x.m4a"), transcript: transcript(), jobState: .complete)
        let model = TranscriptViewModel(files: [imported], playback: RecordingPlayback())
        XCTAssertNil(model.notesContent(for: imported))
    }

    private func draftFile(hasAudio: Bool, sendBlocksCombine: Bool = false) -> TranscriptReviewFile {
        let draftID = UUID()
        return TranscriptReviewFile(
            id: draftID.uuidString,
            runID: UUID().uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/source.m4a"),
            transcript: transcript(),
            jobState: .complete,
            hasAudio: hasAudio,
            draft: MeetingDraftSummary(
                id: draftID,
                revision: 1,
                title: nil,
                defaultTitle: "Meeting",
                phase: .attached(meetingKey: "meeting--x", runID: UUID()),
                status: "Transcribed",
                sendBlocksCombine: sendBlocksCombine
            )
        )
    }

    private func transcript() -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: UUID().uuidString,
            revision: 1,
            title: nil,
            status: .complete,
            createdAt: "2026-11-19T10:00:00Z",
            source: TranscriptSource(filename: "source.m4a", durationMs: 6_000, checksum: "sha256:x"),
            language: "en",
            languageSource: .detected,
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: sampleSegments()
        )
    }

    private func sampleSegments() -> [TranscriptSegment] {
        [(1, 0, 1_000), (2, 2_000, 3_000), (3, 4_500, 6_000)].map { index, start, end in
            TranscriptSegment(
                id: "seg_\(index)",
                speakerID: "speaker_1",
                speakerLabel: "Speaker 1",
                startMs: start,
                endMs: end,
                text: "Turn \(index).",
                overlap: false,
                timingQuality: .asrWord,
                words: [TimedWord(text: "Turn \(index).", startMs: start, endMs: end)]
            )
        }
    }
}

private struct NeverCombiner: TranscriptRecordingCombining {
    func combine(firstFileID: TranscriptReviewFile.ID, secondFileID: TranscriptReviewFile.ID) async throws -> TranscriptReviewFile {
        throw CancellationError()
    }
}

// MARK: - Lifecycle and library operations

@MainActor
final class MeetingNotesLifecycleTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!
    private var draftsURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Notes \(UUID().uuidString)", isDirectory: true)
        storeURL = root.appendingPathComponent("store", isDirectory: true)
        draftsURL = root.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    func testNotesSurviveQuitAndReopenBeforeTranscription() async throws {
        let lifecycle = await makeLifecycle()
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "x")
        let notes = [MeetingNote(text: "Budget", recordingOffsetMilliseconds: 12_000), MeetingNote(text: "Owner: Sam")]
        lifecycle.setNotes(draftID: draft.id, notes: notes)
        XCTAssertEqual(lifecycle.notes(draftID: draft.id), .editable(notes), "the edit is visible at once")
        await lifecycle.flushAll()

        let reopened = await makeLifecycle()
        XCTAssertEqual(reopened.notes(draftID: draft.id), .editable(notes))
        XCTAssertEqual(reopened.noteCount(for: draft.id), 2)
        let file = try XCTUnwrap(rows(reopened).first)
        XCTAssertEqual(file.draft?.noteCount, 2)
    }

    func testTheNoteClockFollowsTheLiveCaptureOnly() async {
        let lifecycle = await makeLifecycle()
        let session = UUID()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date().addingTimeInterval(-10), title: nil, sessionName: "x")
        let running = try? XCTUnwrap(lifecycle.noteClock(draftID: draft.id))
        XCTAssertEqual(Double(running ?? 0), 10_000, accuracy: 1_000)
        lifecycle.capturePaused(true, sessionID: session)
        XCTAssertNil(lifecycle.noteClock(draftID: draft.id), "paused")
        lifecycle.capturePaused(false, sessionID: session)
        lifecycle.captureClock = { _ in 42 }
        XCTAssertEqual(lifecycle.noteClock(draftID: draft.id), 42, "the host's clock (with the Paste Timestamp offset) wins")
        await lifecycle.captureStopped(sessionID: session, reason: .user)
        XCTAssertNil(lifecycle.noteClock(draftID: draft.id), "stopped")
    }

    func testFinishedNotesMoveIntoTheMeetingAndRerunsShowTheSameNotes() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try makeCoordinator()
        let (draft, job) = try await recordAndTranscribe(lifecycle, coordinator, notes: [
            MeetingNote(text: "Decision", recordingOffsetMilliseconds: 500),
        ])
        await reconcile(lifecycle, transcripts)

        let meeting = job.meetingDirectoryURL
        XCTAssertEqual(lifecycle.drafts[draft.id]?.phase, .attached(meetingKey: meeting.lastPathComponent, runID: job.runID))
        XCTAssertEqual(lifecycle.drafts[draft.id]?.notes, [], "one copy: the draft record no longer holds them")
        let sidecarURL = MeetingNotesSidecarFile.url(inMeeting: meeting)
        let permissions = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: meeting).notes(shownBy: draft.id).map(\.text), ["Decision"])
        let stored = try readDraft(draft.id)
        XCTAssertEqual(stored.notes, [])

        // Edits after attachment go to the meeting.
        lifecycle.notesDebounce = .milliseconds(10)
        lifecycle.setNotes(draftID: draft.id, notes: lifecycleNotes(lifecycle, draft.id) + [MeetingNote(text: "Follow up")])
        await lifecycle.flushNotes(draftID: draft.id)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: meeting).notes(shownBy: draft.id).map(\.text), ["Decision", "Follow up"])
        XCTAssertEqual(try readDraft(draft.id).notes, [])

        // Retranscribe and reprocess make new runs in the same meeting: the
        // same notes are shown, nothing is copied.
        let completed = try XCTUnwrap(transcripts.run(withRunID: job.runID)?.job)
        let rerun = try await coordinator.retranscribe(completed, modelProfileID: "default", speakerCount: .automatic, title: nil)
        await coordinator.runPending()
        await reconcile(lifecycle, transcripts)
        let reprocess = try await coordinator.reprocess(try XCTUnwrap(transcripts.run(withRunID: rerun.runID)?.job), speakerCount: .known(2), microphoneSpeakerPrior: false, title: nil)
        await coordinator.runPending()
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(reprocess.meetingDirectoryURL.standardizedFileURL, meeting.standardizedFileURL)
        let row = try XCTUnwrap(rows(lifecycle).first)
        XCTAssertEqual(row.runID, reprocess.runID.uuidString)
        XCTAssertEqual(lifecycleNotes(lifecycle, draft.id).map(\.text), ["Decision", "Follow up"])
        XCTAssertEqual(row.draft?.noteCount, 2)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: meeting).entries.count, 1)

        // Rename leaves the notes where they are.
        _ = try await lifecycle.setTitle(draftID: draft.id, title: "Renamed", basedOnRevision: lifecycle.drafts[draft.id]!.revision, previousTitle: nil)
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(lifecycleNotes(lifecycle, draft.id).map(\.text), ["Decision", "Follow up"])
    }

    func testAHalfDoneAttachmentIsCompletedByReconciliation() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try makeCoordinator()
        let notes = [MeetingNote(text: "latest", recordingOffsetMilliseconds: 100)]
        let (draft, job) = try await recordAndTranscribe(lifecycle, coordinator, notes: notes)

        // A crash after the sidecar write and before the draft was marked:
        // an older copy of the notes is in the meeting, the draft still holds
        // the current ones.
        let stale = MeetingNotesSidecar(entries: [MeetingNotesEntry(
            draftID: draft.id, recorderSessionID: draft.recorderSessionID, attachedRevision: 1,
            notes: [MeetingNote(text: "older")]
        )])
        try MeetingNotesSidecarFile.write(stale, meetingDirectory: job.meetingDirectoryURL)
        await reconcile(lifecycle, transcripts, isLaunch: true)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: job.meetingDirectoryURL).notes(shownBy: draft.id), notes)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.notes, [])

        // An edit that raced the attachment leaves notes in an attached
        // draft; the next pass moves them too.
        let raced = [MeetingNote(text: "raced")]
        try await lifecycle.store.update(id: draft.id, flush: true) { $0.notes = raced }
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: job.meetingDirectoryURL).notes(shownBy: draft.id), raced)
        XCTAssertEqual(lifecycle.drafts[draft.id]?.notes, [])
        XCTAssertEqual(lifecycleNotes(lifecycle, draft.id), raced)
    }

    func testAFailedNotesWriteShowsNotSavedAndBlocksNothingUntilRetried() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try makeCoordinator()
        let (draft, job) = try await recordAndTranscribe(lifecycle, coordinator, notes: [])
        await reconcile(lifecycle, transcripts)
        let meeting = job.meetingDirectoryURL

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: meeting.path)
        lifecycle.setNotes(draftID: draft.id, notes: [MeetingNote(text: "unsaved")])
        await lifecycle.flushNotes(draftID: draft.id)
        guard case .notSaved = lifecycle.saveStates[draft.id] else {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
            return XCTFail("a failed notes write must show Not saved")
        }
        XCTAssertEqual(lifecycleNotes(lifecycle, draft.id).map(\.text), ["unsaved"], "the edit is kept in memory")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: meeting.path)
        _ = await lifecycle.retrySave(draftID: draft.id)
        XCTAssertEqual(lifecycle.saveStates[draft.id], .saved)
        XCTAssertEqual(try MeetingNotesSidecarFile.read(meetingDirectory: meeting).notes(shownBy: draft.id).map(\.text), ["unsaved"])
    }

    func testDeleteAudioKeepsNotesAndFullDeleteRemovesThem() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try makeCoordinator()
        let (draft, job) = try await recordAndTranscribe(lifecycle, coordinator, notes: [MeetingNote(text: "kept", recordingOffsetMilliseconds: 10)])
        await reconcile(lifecycle, transcripts)
        let meeting = job.meetingDirectoryURL

        try transcripts.deleteAudio(containingRunID: job.runID)
        await reconcile(lifecycle, transcripts)
        XCTAssertEqual(lifecycleNotes(lifecycle, draft.id).map(\.text), ["kept"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: MeetingNotesSidecarFile.url(inMeeting: meeting).path))
        let row = try XCTUnwrap(rows(lifecycle).first)
        XCTAssertFalse(row.hasAudio)

        // A pending notes write must not bring the deleted meeting back.
        lifecycle.notesDebounce = .seconds(60)
        lifecycle.setNotes(draftID: draft.id, notes: [MeetingNote(text: "late edit")])
        let model = TranscriptViewModel(files: rows(lifecycle), playback: RecordingPlayback(), fileDeleter: TranscriptStoreFileDeleter(store: transcripts), draftEditor: lifecycle)
        model.delete(fileID: row.id)
        await lifecycle.flushAll()
        for _ in 0 ..< 200 where lifecycle.drafts[draft.id] != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.path), "the notes went with the meeting")
        XCTAssertNil(lifecycle.drafts[draft.id], "the draft record went too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftsURL.appendingPathComponent("\(draft.id.uuidString).json").path))
    }

    func testCombiningCarriesBothNoteSetsShiftedAndClearsTheHandoff() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        let firstNotes = [MeetingNote(text: "a", recordingOffsetMilliseconds: 500), MeetingNote(text: "b")]
        let secondNotes = [MeetingNote(text: "c", recordingOffsetMilliseconds: 1_000), MeetingNote(text: "d")]
        let (first, firstJob) = try await recordAndTranscribe(lifecycle, coordinator, notes: firstNotes, audioSeconds: 2, name: "part 1.wav")
        let (second, secondJob) = try await recordAndTranscribe(lifecycle, coordinator, notes: secondNotes, audioSeconds: 3, name: "part 2.wav")
        try await lifecycle.store.update(id: first.id, flush: true) { draft in
            draft.handoff = MeetingHandoffSettings(agentID: "claude-code", model: "opus", prompt: "Summarise", promptOrigin: .edited)
        }
        await reconcile(lifecycle, transcripts)

        let model = TranscriptViewModel(
            files: rows(lifecycle),
            playback: RecordingPlayback(),
            recordingCombiner: TranscriptStoreRecordingCombiner(store: transcripts),
            draftEditor: lifecycle
        )
        model.selectedFileID = first.id.uuidString
        await model.combine(firstFileID: first.id.uuidString, secondFileID: second.id.uuidString)
        await reconcile(lifecycle, transcripts)

        XCTAssertEqual(model.selectedFileID, first.id.uuidString, "the combined meeting keeps the first recording's row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstJob.meetingDirectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondJob.meetingDirectoryURL.path))
        let combined = try XCTUnwrap(transcripts.runs().first)
        XCTAssertEqual(combined.job.draftID, first.id)

        let sidecar = try MeetingNotesSidecarFile.read(meetingDirectory: combined.job.meetingDirectoryURL)
        XCTAssertEqual(sidecar.entries.map(\.draftID), [first.id, second.id], "each note keeps its source draft")
        XCTAssertEqual(sidecar.entries.map(\.ownerDraftID), [nil, first.id])
        let shown = sidecar.notes(shownBy: first.id)
        XCTAssertEqual(shown.map(\.text), ["a", "b", "c", "d"])
        XCTAssertEqual(shown[0].recordingOffsetMilliseconds, 500)
        XCTAssertNil(shown[1].recordingOffsetMilliseconds, "untimed stays untimed")
        XCTAssertEqual(Double(try XCTUnwrap(shown[2].recordingOffsetMilliseconds)), 3_000, accuracy: 100, "shifted by where the second audio starts")
        XCTAssertNil(shown[3].recordingOffsetMilliseconds)
        XCTAssertEqual(shown.map(\.id), (firstNotes + secondNotes).map(\.id))

        XCTAssertNil(lifecycle.drafts[second.id], "the absorbed draft's record is gone")
        let owner = try XCTUnwrap(lifecycle.drafts[first.id])
        XCTAssertEqual(owner.handoff, MeetingHandoffSettings(), "handoff settings are cleared on the combined meeting")
        XCTAssertEqual(owner.send, .notQueued)
        XCTAssertEqual(owner.phase, .attached(meetingKey: combined.job.meetingDirectoryURL.lastPathComponent, runID: combined.job.runID))
        XCTAssertEqual(lifecycleNotes(lifecycle, first.id).map(\.text), ["a", "b", "c", "d"])
        // Exports and the relay attribute each note to the draft it came from.
        let exported = try lifecycle.exportNotes(draftID: first.id).get()
        XCTAssertEqual(exported.map(\.draftID), [first.id, first.id, second.id, second.id])
        XCTAssertEqual(exported.map(\.offsetMs), shown.map(\.recordingOffsetMilliseconds))
        let relayed = try XCTUnwrap(transcripts.confinedCompletedRuns().runs.first)
        XCTAssertEqual(relayed.notes, exported)
        // A note added between the two sets joins the entry before it, as the
        // write will: the export taken now matches the file written later.
        var edited = shown
        edited.insert(MeetingNote(text: "after c"), at: 3)
        let attributed = sidecar.exportNotes(edited, shownBy: first.id, recorderSessionID: owner.recorderSessionID)
        XCTAssertEqual(attributed.map(\.draftID), [first.id, first.id, second.id, second.id, second.id])
        model.reload(files: rows(lifecycle))
        XCTAssertEqual(model.files.map(\.id), [first.id.uuidString])
        XCTAssertEqual(model.selectedFile?.draft?.noteCount, 4)
    }

    func testExportsAndTheRelayCarryNotesButNeverThePromptOrMCPURL() async throws {
        let prompt = "PRIVATE-PROMPT summarise for the board", mcpURL = "https://private-mcp.example.test/sse"
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try makeCoordinator()
        let (draft, job) = try await recordAndTranscribe(lifecycle, coordinator, notes: [
            MeetingNote(text: "Decision: ship", recordingOffsetMilliseconds: 500),
        ])
        try await lifecycle.store.update(id: draft.id, flush: true) { draft in
            draft.handoff = MeetingHandoffSettings(agentID: "claude-code", model: "opus", mcpURL: mcpURL, prompt: prompt, promptOrigin: .edited)
        }
        await reconcile(lifecycle, transcripts)
        // An edit not written yet is in the export: it is what the row shows.
        lifecycle.notesDebounce = .seconds(60)
        lifecycle.setNotes(draftID: draft.id, notes: lifecycleNotes(lifecycle, draft.id) + [MeetingNote(text: "Untimed follow-up")])

        let model = TranscriptViewModel(files: rows(lifecycle), playback: RecordingPlayback(), draftEditor: lifecycle)
        model.selectedFileID = draft.id.uuidString
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        model.export(Set(TranscriptExportFormat.allCases), to: exports, basename: "meeting")
        XCTAssertTrue(model.exportOutcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(model.toastCenter.visible.last?.kind, .result)

        func read(_ format: TranscriptExportFormat) throws -> String {
            try String(contentsOf: exports.appendingPathComponent("meeting.\(format.fileExtension)"), encoding: .utf8)
        }
        XCTAssertTrue(try read(.plainText).hasSuffix("\n\nNotes\n\n[00:00] Decision: ship\n\n[--:--] Untimed follow-up\n"))
        let json = try JSONSerialization.jsonObject(with: Data(read(.json).utf8)) as? [String: Any]
        let jsonNotes = try XCTUnwrap(json?["notes"] as? [[String: Any]])
        XCTAssertEqual(jsonNotes.map { $0["text"] as? String }, ["Decision: ship", "Untimed follow-up"])
        XCTAssertEqual(Set(jsonNotes.compactMap { $0["draft_id"] as? String }), [draft.id.uuidString.lowercased()])
        let stored = try XCTUnwrap(transcripts.run(withRunID: job.runID)?.transcript)
        XCTAssertEqual(try CanonicalTranscriptCodec.decode(Data(read(.json).utf8)), stored, "a canonical reader sees the transcript only")
        XCTAssertTrue(try read(.knowledgebase).contains("\"Untimed follow-up\""))
        XCTAssertFalse(try read(.subtitles).contains("Decision"), "SRT stays subtitles only")

        model.export(.knowledgebase, toFile: exports.appendingPathComponent("single.kb.json"))
        await model.copyKnowledgebaseToClipboard()

        // The relay's view of the store, once the edit is written.
        await lifecycle.flushNotes(draftID: draft.id)
        let relayed = try XCTUnwrap(transcripts.confinedCompletedRuns().runs.first)
        XCTAssertEqual(relayed.notes.map(\.text), ["Decision: ship", "Untimed follow-up"])

        // Nothing written for others to read carries the private settings:
        // not an export, not the meeting folder the relay walks.
        var written = try FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)
        let meetingFiles = FileManager.default.enumerator(at: job.meetingDirectoryURL, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        written += meetingFiles.filter { ["json", "txt"].contains($0.pathExtension) }
        XCTAssertFalse(written.isEmpty)
        for url in written {
            let text = try String(contentsOf: url, encoding: .utf8)
            for secret in [prompt, mcpURL, "private-mcp", "claude-code", "promptOrigin", "mcpURL"] {
                XCTAssertFalse(text.contains(secret), "\(url.lastPathComponent) carries \(secret)")
            }
        }
        for secret in [prompt, mcpURL] {
            XCTAssertFalse("\(relayed.notes)".contains(secret))
            XCTAssertFalse(model.toastCenter.visible.map(\.text).joined().contains(secret))
        }
    }

    func testAnExportWithUnreadableNotesLeavesThemOutAndSaysSo() async throws {
        let lifecycle = await makeLifecycle()
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let (draft, job) = try await recordAndTranscribe(lifecycle, try makeCoordinator(), notes: [MeetingNote(text: "Kept safe")])
        await reconcile(lifecycle, transcripts)
        await lifecycle.flushNotes(draftID: draft.id)
        // A fresh window (relaunch) finds the notes file damaged.
        try Data("{".utf8).write(to: MeetingNotesSidecarFile.url(inMeeting: job.meetingDirectoryURL))
        let reopened = await makeLifecycle()
        await reconcile(reopened, transcripts, isLaunch: true)
        let model = TranscriptViewModel(files: rows(reopened), playback: RecordingPlayback(), draftEditor: reopened)
        model.selectedFileID = draft.id.uuidString
        let exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        model.export([.plainText], to: exports, basename: "meeting")
        XCTAssertTrue(model.exportOutcomes.allSatisfy(\.succeeded), "the transcript is still exported")
        let toast = try XCTUnwrap(model.toastCenter.visible.last)
        XCTAssertEqual(toast.kind, .failure)
        XCTAssertTrue(toast.text.hasPrefix("Exported TXT. Meeting notes were left out:"), toast.text)
        XCTAssertFalse(try String(contentsOf: exports.appendingPathComponent("meeting.txt"), encoding: .utf8).contains("Notes"))
        XCTAssertEqual(try Data(contentsOf: MeetingNotesSidecarFile.url(inMeeting: job.meetingDirectoryURL)), Data("{".utf8), "left as it was")

        model.export(.subtitles, toFile: exports.appendingPathComponent("meeting.srt"))
        XCTAssertEqual(model.toastCenter.visible.last?.kind, .result, "SRT never carries notes, so nothing was left out")
    }

    func testCombiningRefusesWhenANotesFileCannotBeRead() async throws {
        let transcripts = TranscriptStore(storeDirectoryURL: storeURL)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        let firstSource = try writeAudio(named: "one.wav", seconds: 2)
        let secondSource = try writeAudio(named: "two.wav", seconds: 2.5)
        let firstJob = try await coordinator.enqueue(TranscriptionRequest(sourceURL: firstSource, modelProfileID: "parakeet-v3"))
        let secondJob = try await coordinator.enqueue(TranscriptionRequest(sourceURL: secondSource, modelProfileID: "parakeet-v3"))
        await coordinator.runPending()
        try Data("{".utf8).write(to: MeetingNotesSidecarFile.url(inMeeting: secondJob.meetingDirectoryURL))

        do {
            try await transcripts.combineRecordings(firstRunID: firstJob.runID, secondRunID: secondJob.runID)
            XCTFail("combining would have lost the unreadable notes")
        } catch {
            XCTAssertEqual(error as? TranscriptStoreError, .notesUnreadable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstJob.meetingDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondJob.meetingDirectoryURL.path))
    }

    // MARK: Helpers

    private func makeLifecycle() async -> MeetingDraftLifecycle {
        await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: draftsURL), transcriptStore: TranscriptStore(storeDirectoryURL: storeURL))
    }

    private func makeCoordinator() throws -> TranscriptionCoordinator {
        try TranscriptionCoordinator(configuration: .init(transcriptStoreURL: storeURL), stageRunner: NotesTranscriptRunner())
    }

    /// Records a meeting with notes, stops it, and runs its transcription to
    /// completion, leaving the attachment to reconciliation.
    private func recordAndTranscribe(
        _ lifecycle: MeetingDraftLifecycle,
        _ coordinator: TranscriptionCoordinator,
        notes: [MeetingNote],
        audioSeconds: Double? = nil,
        name: String = "final.m4a"
    ) async throws -> (MeetingDraft, TranscriptionJob) {
        let session = UUID()
        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "x")
        if !notes.isEmpty { lifecycle.setNotes(draftID: draft.id, notes: notes) }
        await lifecycle.captureStopped(sessionID: session, reason: .user)
        await lifecycle.flushNotes(draftID: draft.id)
        let source: URL
        if let audioSeconds {
            source = try writeAudio(named: name, seconds: audioSeconds)
        } else {
            source = root.appendingPathComponent("\(UUID().uuidString).m4a")
            try Data("meeting \(session)".utf8).write(to: source)
        }
        let job = try await coordinator.enqueue(TranscriptionRequest(
            requestID: TranscriptionRequest.recorderRequestID(forSession: session),
            sourceURL: source,
            modelProfileID: audioSeconds == nil ? "default" : "parakeet-v3",
            draftID: draft.id
        ))
        await lifecycle.jobQueued(job)
        await coordinator.runPending()
        return (draft, job)
    }

    private func rows(_ lifecycle: MeetingDraftLifecycle) -> [TranscriptReviewFile] {
        MeetingDraftReviewMerger.files(
            drafts: lifecycle.allDrafts,
            saveStates: lifecycle.saveStates,
            runs: TranscriptStore(storeDirectoryURL: storeURL).runs(),
            environment: .init(live: lifecycle.liveCapture, noteCounts: lifecycle.noteCounts)
        )
    }

    private func reconcile(_ lifecycle: MeetingDraftLifecycle, _ transcripts: TranscriptStore, isLaunch: Bool = false) async {
        await lifecycle.reconcile(sessions: [:], pendingRequests: [], runs: transcripts.runs(), autoTranscribe: true, isLaunch: isLaunch)
    }

    private func lifecycleNotes(_ lifecycle: MeetingDraftLifecycle, _ id: UUID) -> [MeetingNote] {
        lifecycle.notes(draftID: id).notes
    }

    private func readDraft(_ id: UUID) throws -> MeetingDraft {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingDraft.self, from: Data(contentsOf: draftsURL.appendingPathComponent("\(id.uuidString).json")))
    }

    private func writeAudio(named name: String, seconds: Double) throws -> URL {
        let url = root.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0 ..< Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.02) * 0.4 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// Writes a one-turn canonical transcript at the assembling stage.
private struct NotesTranscriptRunner: TranscriptionStageRunning {
    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        guard stage == .assembling else { return .init() }
        let url = job.runDirectoryURL.appendingPathComponent(TranscriptRunArtifact.canonicalTranscript)
        let transcript = CanonicalTranscript(
            transcriptID: job.runID.uuidString,
            revision: 1,
            title: job.request.title,
            status: .complete,
            createdAt: "2026-11-19T10:00:00Z",
            source: TranscriptSource(filename: "final.m4a", durationMs: 1_000, checksum: "sha256:meeting"),
            language: "en",
            languageSource: .detected,
            speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .unmatched, labelSnapshot: "Speaker 1")],
            segments: [TranscriptSegment(
                id: "seg_1", speakerID: "speaker_1", speakerLabel: "Speaker 1", startMs: 0, endMs: 800,
                text: "Hello.", overlap: false, timingQuality: .asrWord,
                words: [TimedWord(text: "Hello.", startMs: 0, endMs: 800)]
            )]
        )
        try CanonicalTranscriptCodec.encode(transcript).write(to: url)
        return .init(artifactURL: url)
    }
}
