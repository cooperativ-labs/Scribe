import Foundation
import XCTest
@testable import Transcription

/// The handoff tray bound to meeting drafts: settings seeded once per draft,
/// kept in the draft, never shared between meetings, and sent with the
/// meeting's own notes.
@MainActor
final class AgentHandoffDraftTests: XCTestCase {
    private var root: URL!
    private var draftsURL: URL { root.appending(path: "drafts") }
    private let defaultsSuite = "AgentHandoffDraftTests-\(UUID().uuidString)"
    private lazy var preferences = TranscriptAgentPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AgentHandoffDraftTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }

    func testSettingsAreSeededOncePerDraftFromWhatWasLastSent() async throws {
        preferences.recordSend(agentID: "claude", model: "opus", effort: .high)
        preferences.mcpURL = "https://kb.example.com/mcp"
        let lifecycle = await makeLifecycle()
        let session = UUID()

        let draft = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "Meeting")
        XCTAssertEqual(draft.handoff.agentID, "claude")
        XCTAssertEqual(draft.handoff.model, "opus")
        XCTAssertEqual(draft.handoff.effort, "high")
        XCTAssertEqual(draft.handoff.mcpURL, "https://kb.example.com/mcp")
        XCTAssertEqual(draft.handoff.folder, .unset)
        XCTAssertEqual(draft.handoff.promptOrigin, .default)

        // A later send elsewhere does not reach into this meeting, and
        // resuming the same recording does not seed it again.
        preferences.recordSend(agentID: "codex", model: "gpt-5.5", effort: nil)
        let resumed = await lifecycle.captureStarted(sessionID: session, startedAt: Date(), title: nil, sessionName: "Meeting")
        XCTAssertEqual(resumed.id, draft.id)
        XCTAssertEqual(lifecycle.handoffSettings(draftID: draft.id)?.agentID, "claude")

        // The next meeting starts from the newer send.
        let next = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "Next")
        XCTAssertEqual(next.handoff.agentID, "codex")
        XCTAssertEqual(next.handoff.model, "gpt-5.5")
    }

    func testHandoffEditsAreSavedWithTheDraftAndSurviveARelaunch() async throws {
        let lifecycle = await makeLifecycle()
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "Meeting")
        var edited = draft.handoff
        edited.agentID = "codex"
        edited.folder = .none
        edited.prompt = "Only the decisions."
        edited.promptOrigin = .edited
        lifecycle.setHandoffSettings(draftID: draft.id, edited)
        XCTAssertEqual(lifecycle.handoffSettings(draftID: draft.id), edited, "applied to the mirror at once")

        await lifecycle.flushNotes(draftID: draft.id)
        let relaunched = await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: draftsURL), preferences: preferences)

        XCTAssertEqual(relaunched.handoffSettings(draftID: draft.id), edited)
        let permissions = try FileManager.default.attributesOfItem(atPath: draftsURL.appending(path: "\(draft.id.uuidString).json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testTwoMeetingsNeverShareAgentOrPromptAndEachSendsItsOwnNotes() async throws {
        let lifecycle = await makeLifecycle()
        let first = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "First")
        let second = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "Second")
        lifecycle.setNotes(draftID: first.id, notes: [MeetingNote(text: "First meeting note", recordingOffsetMilliseconds: 5_000)])
        lifecycle.setNotes(draftID: second.id, notes: [MeetingNote(text: "Second meeting note", recordingOffsetMilliseconds: nil)])
        await lifecycle.flushNotes(draftID: first.id)
        await lifecycle.flushNotes(draftID: second.id)

        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(
            agents: [TranscriptAgentHandoffTests.claude, TranscriptAgentHandoffTests.codex],
            folders: [TranscriptAgentHandoffTests.repository, TranscriptAgentHandoffTests.notes]
        )
        let files = [try finishedRow(for: first, lifecycle), try finishedRow(for: second, lifecycle)]
        let viewModel = TranscriptViewModel(files: files, playback: AgentPlaybackStub(), agentDispatcher: dispatcher, agentPreferences: preferences, draftEditor: lifecycle)
        let firstTray = viewModel.handoffTarget(for: files[0])
        let secondTray = viewModel.handoffTarget(for: files[1])
        XCTAssertEqual(firstTray, .draft(first.id))
        XCTAssertEqual(secondTray, .draft(second.id))

        await viewModel.loadAgentEnvironment(for: firstTray)
        viewModel.selectHandoffAgent(TranscriptAgentHandoffTests.codex.id, for: firstTray)
        viewModel.selectHandoffFolder(.folder(TranscriptAgentHandoffTests.notes.id), for: firstTray)
        viewModel.setHandoffPrompt("First meeting's prompt", for: firstTray)
        viewModel.setHandoffModel("gpt-5.5", for: firstTray)

        // Selecting the other meeting shows its own settings, untouched.
        viewModel.selectedFileID = files[1].id
        await viewModel.loadAgentEnvironment(for: secondTray)
        XCTAssertEqual(viewModel.handoffAgent(for: secondTray)?.id, TranscriptAgentHandoffTests.claude.id)
        XCTAssertEqual(viewModel.handoffSettings(for: secondTray).prompt, TranscriptAgentRequest.defaultInstruction)
        XCTAssertEqual(viewModel.handoffSettings(for: secondTray).model, "")
        XCTAssertEqual(viewModel.handoffFolder(for: secondTray)?.id, TranscriptAgentHandoffTests.repository.id)

        // The first meeting is sent while the second is selected: the
        // request is the first meeting's, built from its own draft.
        let sent = await viewModel.sendToAgent(firstTray)
        XCTAssertTrue(sent)
        let request = try XCTUnwrap(dispatcher.requests.last)
        XCTAssertEqual(request.agent.id, TranscriptAgentHandoffTests.codex.id)
        XCTAssertEqual(request.model, "gpt-5.5")
        XCTAssertEqual(request.folder?.id, TranscriptAgentHandoffTests.notes.id)
        XCTAssertEqual(request.instruction, "First meeting's prompt")
        XCTAssertEqual(request.notes.map(\.text), ["First meeting note"])
        XCTAssertNil(viewModel.handoffStatus(for: secondTray), "the other tray shows nothing of this send")

        _ = await viewModel.sendToAgent(secondTray)
        let other = try XCTUnwrap(dispatcher.requests.last)
        XCTAssertEqual(other.agent.id, TranscriptAgentHandoffTests.claude.id)
        XCTAssertEqual(other.notes.map(\.text), ["Second meeting note"])
        XCTAssertEqual(other.instruction, TranscriptAgentRequest.defaultInstruction)

        // The settings are the drafts', on disk, not the window's.
        XCTAssertEqual(lifecycle.handoffSettings(draftID: first.id)?.agentID, "codex")
        XCTAssertEqual(lifecycle.handoffSettings(draftID: second.id)?.agentID, "claude")
        XCTAssertEqual(lifecycle.handoffSettings(draftID: first.id)?.promptOrigin, .edited)
    }

    func testAMeetingStillRecordingCanBeSetUpButNotSent() async throws {
        let lifecycle = await makeLifecycle()
        let draft = await lifecycle.captureStarted(sessionID: UUID(), startedAt: Date(), title: nil, sessionName: "Live")
        let summary = try XCTUnwrap(lifecycle.summary(for: draft.id))
        let placeholder = TranscriptReviewFile(
            id: draft.id.uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/dev/null"),
            transcript: nil,
            jobState: .recording(startedAt: Date(), isPaused: false),
            hasAudio: false,
            draft: summary
        )
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [TranscriptAgentHandoffTests.claude], folders: [])
        let viewModel = TranscriptViewModel(files: [placeholder], playback: AgentPlaybackStub(), agentDispatcher: dispatcher, agentPreferences: preferences, draftEditor: lifecycle)
        let tray = viewModel.handoffTarget(for: placeholder)

        await viewModel.loadAgentEnvironment(for: tray)
        viewModel.setHandoffPrompt("Write it up for the team.", for: tray)

        XCTAssertEqual(viewModel.handoffProblem(for: tray), "The transcript isn\u{2019}t ready yet.")
        let sent = await viewModel.sendToAgent(tray)
        XCTAssertFalse(sent)
        XCTAssertTrue(dispatcher.requests.isEmpty)
        XCTAssertEqual(lifecycle.handoffSettings(draftID: draft.id)?.prompt, "Write it up for the team.")
        XCTAssertEqual(viewModel.handoffNotes(for: tray), .editable([]))
    }

    // MARK: - Helpers

    private func makeLifecycle() async -> MeetingDraftLifecycle {
        await MeetingDraftLifecycle(store: MeetingDraftStore(directoryURL: draftsURL), preferences: preferences)
    }

    /// A row for a draft whose transcript is ready, with its notes still in
    /// the draft record (as before attachment).
    private func finishedRow(for draft: MeetingDraft, _ lifecycle: MeetingDraftLifecycle) throws -> TranscriptReviewFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "two-speakers", withExtension: "json"))
        let transcript = try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
        return TranscriptReviewFile(
            id: draft.id.uuidString,
            runID: UUID().uuidString,
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/\(draft.id.uuidString).flac"),
            transcript: transcript,
            jobState: .complete,
            draft: try XCTUnwrap(lifecycle.summary(for: draft.id))
        )
    }
}
