import AppKit
import Foundation
import SwiftUI
@testable import Transcription
import XCTest

/// Typing notes and prompts must stay fluid. Each review reload rereads the
/// store and redraws the whole Transcripts window, so typing must not cause
/// one per keystroke, and a reload must not decode every transcript again.
@MainActor
final class NotesTypingResponsivenessTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Typing \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recordingLifecycle() async -> (MeetingDraftLifecycle, MeetingDraft) {
        let lifecycle = await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: root.appending(path: "drafts"), debounce: .milliseconds(10)))
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "x")
        return (lifecycle, draft)
    }

    func testTypingIntoANoteAsksForNoReloadAndOnlyANewNoteDoes() async throws {
        let (lifecycle, draft) = await recordingLifecycle()
        var reloads = 0
        lifecycle.didChange = { reloads += 1 }
        let first = UUID()
        var text = ""
        for character in "Pricing is late" {
            text.append(character)
            lifecycle.setNotes(draftID: draft.id, notes: [MeetingNote(id: first, text: text, recordingOffsetMilliseconds: 1_000)])
            await Task.yield()
        }
        await lifecycle.flushNotes(draftID: draft.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reloads, 1, "the first character makes a note, which the row counts; the rest are not news to the list")

        reloads = 0
        lifecycle.setNotes(draftID: draft.id, notes: [
            MeetingNote(id: first, text: text, recordingOffsetMilliseconds: 1_000),
            MeetingNote(text: "A", recordingOffsetMilliseconds: 2_000),
        ])
        await lifecycle.flushNotes(draftID: draft.id)
        XCTAssertGreaterThanOrEqual(reloads, 1, "a second note changes the row's count")
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["Pricing is late", "A"])
    }

    func testTypingAPromptAsksForNoReloadButChangingTheAgentDoes() async throws {
        let (lifecycle, draft) = await recordingLifecycle()
        var reloads = 0
        lifecycle.didChange = { reloads += 1 }
        var settings = try XCTUnwrap(lifecycle.handoffSettings(draftID: draft.id))
        for character in "Summarise" {
            settings.prompt.append(character)
            lifecycle.setHandoffSettings(draftID: draft.id, settings)
            await Task.yield()
        }
        await lifecycle.flushNotes(draftID: draft.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reloads, 0)

        settings.agentID = "codex"
        lifecycle.setHandoffSettings(draftID: draft.id, settings)
        await lifecycle.flushNotes(draftID: draft.id)
        XCTAssertGreaterThanOrEqual(reloads, 1, "a queued send's row names the agent")
        XCTAssertEqual(lifecycle.handoffSettings(draftID: draft.id)?.prompt.hasSuffix("Summarise"), true)
    }

    func testADecodedTranscriptIsReusedUntilItsFileIsReplacedOrRemoved() throws {
        let cache = CanonicalTranscriptDecodeCache()
        let url = root.appending(path: TranscriptRunArtifact.canonicalTranscript)
        try CanonicalTranscriptCodec.encode(transcript(revision: 1)).write(to: url, options: .atomic)
        XCTAssertEqual(cache.transcript(at: url, fileManager: .default)?.revision, 1)
        XCTAssertEqual(cache.transcript(at: url, fileManager: .default)?.revision, 1)
        XCTAssertEqual(cache.count, 1)

        // Every store write is an atomic replace.
        try CanonicalTranscriptCodec.encode(transcript(revision: 2)).write(to: url, options: .atomic)
        XCTAssertEqual(cache.transcript(at: url, fileManager: .default)?.revision, 2, "a replaced file is read again")

        try FileManager.default.removeItem(at: url)
        cache.removeMissing(fileManager: .default)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.transcript(at: url, fileManager: .default))
    }

    /// A long status line once reported its height for a near-zero width,
    /// which the Transcripts window took as the detail's minimum height: the
    /// whole window content moved up past the title bar when a send was
    /// queued or failed.
    func testTheTraysHeightStaysBoundedWhenMeasuredNarrow() async throws {
        let (lifecycle, draft) = await recordingLifecycle()
        let model = TranscriptViewModel(
            files: [TranscriptReviewFile(
                id: draft.id.uuidString,
                sourceSnapshotURL: URL(fileURLWithPath: "/dev/null"),
                transcript: nil,
                jobState: .recording(startedAt: Date(), isPaused: false),
                hasAudio: false,
                draft: try XCTUnwrap(lifecycle.summary(for: draft.id))
            )],
            playback: TypingPlaybackStub(),
            draftEditor: lifecycle
        )
        let target = AgentHandoffTarget.draft(draft.id)
        model.handoffStatuses[target] = .failed(String(repeating: "Latch could not start the agent in the folder chosen. ", count: 6))
        let host = NSHostingController(rootView: AgentHandoffTray(viewModel: model, target: target, style: .full))
        let narrow = host.sizeThatFits(in: CGSize(width: 1, height: 100_000))
        let compact = NSHostingController(rootView: AgentHandoffTray(viewModel: model, target: target, style: .compact))
            .sizeThatFits(in: CGSize(width: 1, height: 100_000))
        XCTAssertLessThan(narrow.height, 600, "the window's minimum height is 600")
        XCTAssertLessThan(compact.height, 400)
    }

    /// List rows ask for neighbours, paragraphs and the playing source many
    /// times per redraw; the ordering is worked out once per version of the
    /// turns and must follow every edit.
    func testTheTimeOrderFollowsEditsAndSelectionChanges() throws {
        func turn(_ id: String, _ speaker: String, _ start: Int) -> TranscriptSegment {
            TranscriptSegment(id: id, speakerID: speaker, speakerLabel: speaker, startMs: start, endMs: start + 500,
                              text: "Words \(id).", overlap: false, timingQuality: .asrWord,
                              words: [TimedWord(text: "Words", startMs: start, endMs: start + 500)])
        }
        func file(_ id: String, _ segments: [TranscriptSegment]) -> TranscriptReviewFile {
            var transcript = transcript(revision: 1)
            transcript = transcript.replacing(segments: segments)
            return TranscriptReviewFile(id: id, sourceSnapshotURL: URL(fileURLWithPath: "/tmp/\(id).m4a"), transcript: transcript, jobState: .complete)
        }
        let model = TranscriptViewModel(
            files: [
                file("one", [turn("c", "s1", 2_000), turn("a", "s1", 0), turn("b", "s2", 1_000)]),
                file("two", [turn("x", "s1", 0)]),
            ],
            playback: TypingPlaybackStub()
        )
        XCTAssertEqual(model.chronologicalSegments.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.segment(after: "a")?.id, "b")
        XCTAssertEqual(model.segment(before: "c")?.id, "b")
        XCTAssertNil(model.segment(before: "a"))
        XCTAssertEqual(model.chronologicalParagraphs.count, 3)
        XCTAssertEqual(model.paragraph(containingSegmentID: "c")?.sourceSegmentIDs, ["c"])

        model.merge(segmentID: "a", withNext: true)
        XCTAssertEqual(model.chronologicalSegments.count, 2, "an edit is seen at once")
        XCTAssertNil(model.paragraph(containingSegmentID: "b"))
        XCTAssertEqual(model.segment(after: model.chronologicalSegments[0].id)?.id, "c")

        model.selectedFileID = "two"
        XCTAssertEqual(model.chronologicalSegments.map(\.id), ["x"], "another transcript is another order")
        XCTAssertNil(model.segment(after: "a"))
    }

    private func transcript(revision: Int) -> CanonicalTranscript {
        CanonicalTranscript(
            transcriptID: "t",
            revision: revision,
            title: nil,
            status: .complete,
            createdAt: "2026-11-20T10:00:00Z",
            source: TranscriptSource(filename: "source.m4a", durationMs: 1_000, checksum: "sha256:x"),
            language: "en",
            languageSource: .detected,
            speakers: [],
            segments: []
        )
    }
}

private final class TypingPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}
