import AppKit
import SwiftUI
@testable import Transcription
import XCTest

// MARK: - Close policy (decision 13)

final class MeetingNotesPanelClosePolicyTests: XCTestCase {
    private func inputs(
        hasFocus: Bool = false,
        hasMarkedText: Bool = false,
        hasUnsavedEdits: Bool = false,
        isTranscriptReady: Bool = true,
        wasOpenBeforeTranscript: Bool = true,
        trayState: AgentHandoffTrayState = .manual(nil)
    ) -> MeetingNotesPanelClosePolicy.Inputs {
        .init(
            hasFocus: hasFocus,
            hasMarkedText: hasMarkedText,
            hasUnsavedEdits: hasUnsavedEdits,
            isTranscriptReady: isTranscriptReady,
            wasOpenBeforeTranscript: wasOpenBeforeTranscript,
            trayState: trayState
        )
    }

    func testItMayCloseOnlyOnceTheTranscriptIsReadyAndNothingIsQueued() {
        XCTAssertTrue(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs()))
        XCTAssertFalse(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(isTranscriptReady: false)), "still recording or transcribing")
        XCTAssertFalse(
            MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(wasOpenBeforeTranscript: false)),
            "opened on a finished meeting: never closes under the person"
        )
    }

    func testItNeverClosesWhileFocusedComposingOrUnsaved() {
        XCTAssertFalse(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(hasFocus: true)))
        XCTAssertFalse(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(hasMarkedText: true)))
        XCTAssertFalse(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(hasUnsavedEdits: true)))
    }

    func testItNeverClosesWhileASendIsQueuedHeldUnderWayOrShowingItsResult() {
        let outcome = TranscriptAgentOutcome(sessionName: "s", agentName: "Claude Code", folderName: nil)
        let blocking: [AgentHandoffTrayState] = [
            .waiting,
            .held(.interrupted),
            .canQueue,
            .unconfirmed("Scribe could not tell whether the agent started."),
            .manual(.sending),
            .manual(.sent(outcome)),
            .manual(.failed("Latch is not installed.")),
        ]
        for state in blocking {
            XCTAssertFalse(MeetingNotesPanelClosePolicy.mayCloseAutomatically(inputs(trayState: state)), "\(state)")
        }
    }
}

// MARK: - Tray pills wrap in the narrow panel

final class HandoffFlowLayoutTests: XCTestCase {
    private let pills = [CGSize(width: 90, height: 24), CGSize(width: 120, height: 24), CGSize(width: 110, height: 24), CGSize(width: 30, height: 24)]

    func testWithRoomThePillsStayOnOneLine() {
        let placements = HandoffFlowLayout.arrange(sizes: pills, width: nil, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(placements.map(\.origin.y), [0, 0, 0, 0])
        XCTAssertEqual(HandoffFlowLayout.bounds(of: placements), CGSize(width: 90 + 120 + 110 + 30 + 18, height: 24))
    }

    func testInANarrowPanelThePillsWrapAndNeverOverflow() {
        let placements = HandoffFlowLayout.arrange(sizes: pills, width: 230, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(placements.map(\.origin), [
            CGPoint(x: 0, y: 0), CGPoint(x: 96, y: 0),
            CGPoint(x: 0, y: 30), CGPoint(x: 116, y: 30),
        ])
        XCTAssertLessThanOrEqual(HandoffFlowLayout.bounds(of: placements).width, 230)
    }

    func testAPillWiderThanThePanelIsGivenThePanelsWidth() {
        let placements = HandoffFlowLayout.arrange(sizes: [CGSize(width: 50, height: 24), CGSize(width: 500, height: 24)], width: 300, spacing: 6, lineSpacing: 6)
        XCTAssertEqual(placements[1], .init(origin: CGPoint(x: 0, y: 30), size: CGSize(width: 300, height: 24)))
    }
}

// MARK: - Panel and controller

@MainActor
final class MeetingNotesPanelTests: XCTestCase {
    private var root: URL!
    private var windows: [NSWindow] = []
    private var controllers: [MeetingNotesPanelController] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Notes Panel \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(MeetingNotesPanelController.frameAutosaveName)")
    }

    override func tearDown() async throws {
        for controller in controllers { controller.panel.orderOut(nil) }
        for window in windows { window.close() }
        controllers = []
        windows = []
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(MeetingNotesPanelController.frameAutosaveName)")
        try? FileManager.default.removeItem(at: root)
    }

    func testThePanelTakesTypingWithoutActivatingAndFollowsEverySpaceIncludingFullScreen() {
        let panel = MeetingNotesPanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.titled), "a title bar to move it by")
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.collectionBehavior.contains(.transient), "it is not dismissed like a menu")
        XCTAssertFalse(panel.hidesOnDeactivate, "Scribe is rarely the active app while it is used")
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.title, "Meeting Notes")
    }

    func testEditingShortcutsAreSentByThePanelItself() throws {
        func selector(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> Selector? {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
            ))
            return MeetingNotesPanel.editingSelector(for: event)
        }
        XCTAssertEqual(try selector("w", .command), #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(try selector("z", .command), Selector(("undo:")))
        XCTAssertEqual(try selector("Z", [.command, .shift]), Selector(("redo:")))
        XCTAssertEqual(try selector("v", .command), #selector(NSText.paste(_:)))
        XCTAssertNil(try selector("n", .command))
        XCTAssertNil(try selector("w", [.command, .option]))
    }

    func testShowingBindsTheDraftAndPutsTheCaretInItsNotes() async throws {
        let (lifecycle, draft) = try await recordingDraft(notes: [MeetingNote(text: "Pricing", recordingOffsetMilliseconds: 5_000)])
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)

        controller.show(draftID: draft.id)
        let editor = try await editorView(in: controller.panel)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.draftID, draft.id)
        XCTAssertEqual(editor.textView.string, "Pricing")
        XCTAssertEqual(editor.draftID, draft.id)
        await spin()
        XCTAssertTrue(controller.panel.firstResponder === editor.textView, "the caret is in the notes")
    }

    func testEditsInThePanelAndTheWindowGoThroughTheSameDraft() async throws {
        let (lifecycle, draft) = try await recordingDraft(notes: [MeetingNote(text: "First")])
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        let panelEditor = try await editorView(in: controller.panel)

        // The Transcripts window's editor for the same draft and model.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeetingNotesEditorPane(viewModel: model, draftID: draft.id).frame(width: 400, height: 300))
        windows.append(window)
        let windowEditor = try await editorView(in: window)
        XCTAssertEqual(windowEditor.textView.string, "First")

        // Typed in the panel: the draft has it and the window shows it.
        panelEditor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        panelEditor.textView.insertText("\n\nSecond", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["First", "Second"])
        try await waitUntil { windowEditor.textView.string == "First\n\nSecond" }

        // Typed in the window: the panel shows it, with its caret kept.
        panelEditor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        windowEditor.textView.setSelectedRange(NSRange(location: (windowEditor.textView.string as NSString).length, length: 0))
        windowEditor.textView.insertText(" item", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["First", "Second item"])
        try await waitUntil { panelEditor.textView.string == "First\n\nSecond item" }
        XCTAssertEqual(panelEditor.textView.selectedRange(), NSRange(location: 2, length: 0), "the caret does not jump")
        XCTAssertEqual(
            lifecycle.notes(draftID: draft.id).notes.map(\.id).count, 2,
            "one note set, not one per surface"
        )
    }

    func testLosingKeyLeavesThePanelOpenWhileTheMeetingIsBeingRecorded() async throws {
        let (lifecycle, draft) = try await recordingDraft()
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        _ = try await editorView(in: controller.panel)

        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        windows.append(other)
        other.makeKeyAndOrderFront(nil)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        await spin()
        XCTAssertTrue(controller.isVisible)
    }

    func testItClosesItselfWhenTheTranscriptArrivesAndNothingIsQueuedOrUnsaved() async throws {
        let (lifecycle, draft) = try await recordingDraft(notes: [MeetingNote(text: "Kept")])
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        _ = try await editorView(in: controller.panel)
        // The person moves back to the meeting.
        controller.panel.makeFirstResponder(nil)
        controller.panel.resignKey()

        model.reload(files: [try finished(draft, lifecycle)])
        try await waitUntil { !controller.isVisible }
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["Kept"])
    }

    func testItStaysOpenWhenTheTranscriptArrivesWhileASendIsShowing() async throws {
        let (lifecycle, draft) = try await recordingDraft()
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        _ = try await editorView(in: controller.panel)
        controller.panel.resignKey()

        model.reload(files: [try finished(draft, lifecycle, send: .queued(operationID: UUID(), queuedAt: Date()))])
        await spin(0.3)
        XCTAssertTrue(controller.isVisible, "a queued send is still to come")
        let inputs = try XCTUnwrap(controller.closeInputs())
        XCTAssertEqual(inputs.trayState, .waiting)
    }

    func testTextBeingComposedKeepsThePanelOpenAndIsCommittedOnClose() async throws {
        let (lifecycle, draft) = try await recordingDraft()
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        let editor = try await editorView(in: controller.panel)
        controller.panel.makeFirstResponder(editor.textView)
        // A CJK input method composing 会議 (kaigi) before committing it.
        editor.textView.setMarkedText("かいぎ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.textView.hasMarkedText())
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes, [], "composition is not a note yet")

        model.reload(files: [try finished(draft, lifecycle)])
        await spin(0.3)
        XCTAssertTrue(controller.isVisible, "never closes while text is being composed")
        XCTAssertEqual(controller.closeInputs()?.hasMarkedText, true)

        controller.close()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(lifecycle.notes(draftID: draft.id).notes.map(\.text), ["かいぎ"], "closing commits, it does not drop")
    }

    func testClosingWritesTheNotesAndUnbindsTheDraft() async throws {
        let (lifecycle, draft) = try await recordingDraft()
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        let editor = try await editorView(in: controller.panel)
        editor.textView.insertText("Decision: ship", replacementRange: NSRange(location: NSNotFound, length: 0))

        controller.close()
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.draftID)
        try await waitUntil { !lifecycle.hasUnsavedEdits(draftID: draft.id) }
        await lifecycle.flushNotes(draftID: draft.id)
        let reopened = await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: root.appending(path: "drafts")))
        XCTAssertEqual(reopened.notes(draftID: draft.id).notes.map(\.text), ["Decision: ship"])
    }

    func testShowingAnotherMeetingSwitchesTheEditorToIt() async throws {
        let (lifecycle, first) = try await recordingDraft(notes: [MeetingNote(text: "One")])
        let second = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "Two")
        lifecycle.setNotes(draftID: second.id, notes: [MeetingNote(text: "Two")])
        let model = viewModel(lifecycle, files: [try placeholder(first, lifecycle), try placeholder(second, lifecycle)])
        let controller = makeController(model)

        controller.show(draftID: first.id)
        _ = try await editorView(in: controller.panel)
        controller.show(draftID: second.id)
        try await waitUntil { (try? self.editorViewNow(in: controller.panel))?.textView.string == "Two" }
        XCTAssertEqual(controller.draftID, second.id)
    }

    func testTheRememberedFrameIsUsedWhenItIsStillOnAScreen() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
        let (lifecycle, draft) = try await recordingDraft()
        let model = viewModel(lifecycle, files: [try placeholder(draft, lifecycle)])
        let controller = makeController(model)
        controller.show(draftID: draft.id)
        let moved = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 60, width: 380, height: 420)
        controller.panel.setFrame(moved, display: false)
        controller.panel.saveFrame(usingName: MeetingNotesPanelController.frameAutosaveName)
        controller.close()

        let again = makeController(model)
        again.show(draftID: draft.id)
        XCTAssertEqual(again.panel.frame.origin, moved.origin)
        XCTAssertEqual(again.panel.frame.size, moved.size)
    }

    // MARK: Helpers

    private func makeController(_ model: TranscriptViewModel) -> MeetingNotesPanelController {
        let controller = MeetingNotesPanelController(viewModel: model)
        controllers.append(controller)
        return controller
    }

    private func recordingDraft(notes: [MeetingNote] = []) async throws -> (MeetingDraftLifecycle, MeetingDraft) {
        let lifecycle = await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: root.appending(path: "drafts")))
        lifecycle.notesDebounce = .milliseconds(10)
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: "Weekly sync", sessionName: "Session")
        if !notes.isEmpty { lifecycle.setNotes(draftID: draft.id, notes: notes) }
        return (lifecycle, draft)
    }

    private func viewModel(_ lifecycle: MeetingDraftLifecycle, files: [TranscriptReviewFile]) -> TranscriptViewModel {
        TranscriptViewModel(files: files, playback: PanelPlaybackStub(), draftEditor: lifecycle)
    }

    private func placeholder(_ draft: MeetingDraft, _ lifecycle: MeetingDraftLifecycle) throws -> TranscriptReviewFile {
        TranscriptReviewFile(
            id: draft.id.uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/dev/null"),
            transcript: nil,
            jobState: .recording(startedAt: Date(), isPaused: false),
            hasAudio: false,
            draft: try XCTUnwrap(lifecycle.summary(for: draft.id))
        )
    }

    private func finished(_ draft: MeetingDraft, _ lifecycle: MeetingDraftLifecycle, send: MeetingSend = .notQueued) throws -> TranscriptReviewFile {
        let summary = try XCTUnwrap(lifecycle.summary(for: draft.id))
        return TranscriptReviewFile(
            id: draft.id.uuidString,
            runID: UUID().uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/source.m4a"),
            transcript: CanonicalTranscript(
                transcriptID: UUID().uuidString,
                revision: 1,
                title: "Weekly sync",
                status: .complete,
                createdAt: "2026-11-19T10:00:00Z",
                source: TranscriptSource(filename: "source.m4a", durationMs: 6_000, checksum: "sha256:x"),
                language: "en",
                languageSource: .detected,
                speakers: [],
                segments: []
            ),
            jobState: .complete,
            draft: MeetingDraftSummary(
                id: summary.id,
                revision: summary.revision,
                title: summary.title,
                defaultTitle: summary.defaultTitle,
                noteCount: summary.noteCount,
                phase: .attached(meetingKey: "meeting--x", runID: UUID()),
                status: "Transcribed",
                send: send
            )
        )
    }

    private func editorViewNow(in window: NSWindow) throws -> MeetingNotesEditorView {
        window.contentView?.layoutSubtreeIfNeeded()
        return try XCTUnwrap(MeetingNotesPanelController.editorView(in: window.contentView))
    }

    private func editorView(in window: NSWindow) async throws -> MeetingNotesEditorView {
        for _ in 0 ..< 50 {
            if let editor = try? editorViewNow(in: window) { return editor }
            await spin(0.02)
        }
        return try editorViewNow(in: window)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out")
                return
            }
            await spin(0.02)
        }
    }

    private func spin(_ seconds: TimeInterval = 0.05) async {
        pump(seconds)
        await Task.yield()
    }

    /// Lets AppKit and SwiftUI lay out and deliver updates.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}

private final class PanelPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}
