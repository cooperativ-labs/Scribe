import Foundation
import XCTest
@testable import Transcription

@MainActor
final class TranscriptAgentHandoffTests: XCTestCase {
    func testWithoutAHostDispatcherTheActionIsNotOffered() async throws {
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub())

        XCTAssertFalse(viewModel.canSendToAgent)
        await viewModel.loadAgentEnvironment()
        XCTAssertNil(viewModel.agentEnvironment)
        // A keyboard route could still reach the model; it must be inert.
        let sent = await viewModel.sendToAgent()
        XCTAssertFalse(sent)
        XCTAssertNil(viewModel.agentMessage)
    }

    func testLoadingTakesTheFirstAgentAndTheFirstFolderThatIsStillThere() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(
            agents: [Self.claude, Self.codex],
            folders: [Self.missingFolder, Self.repository]
        )
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)

        XCTAssertTrue(viewModel.canSendToAgent)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.selectedAgentID, Self.claude.id)
        // The first folder is gone, so the selection lands on the one that
        // can actually be sent to rather than on a dead-end choice.
        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.repository.id)
        XCTAssertNil(viewModel.agentHandoffProblem)
        XCTAssertTrue(viewModel.canSubmitAgentHandoff)
    }

    func testASelectionThatNoLongerExistsIsMovedOntoSomethingThatDoes() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.selectedAgentID = Self.codex.id

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.selectedAgentID, Self.claude.id)
    }

    func testConnectingAFolderSelectsTheOneThatWasJustConnected() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()
        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.repository.id)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.notes, Self.repository])
        await viewModel.connectAgentFolder()

        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.notes.id)
    }

    func testSendingCarriesTheChosenAgentFolderAndInstruction() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository, Self.notes])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.selectedAgentID = Self.codex.id
        viewModel.selectedAgentFolderID = Self.notes.id
        viewModel.agentInstruction = "  Turn the action items into issues.  "

        let sent = await viewModel.sendToAgent()

        XCTAssertTrue(sent)
        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.agent.id, Self.codex.id)
        XCTAssertEqual(request.folder.id, Self.notes.id)
        XCTAssertEqual(request.instruction, "Turn the action items into issues.")
        XCTAssertEqual(request.transcript.transcriptID, try fixture(named: "two-speakers").transcriptID)
        XCTAssertEqual(viewModel.agentMessage?.isFailure, false)
        XCTAssertEqual(
            viewModel.agentMessage?.text,
            "Sent to Codex in Notes as \u{201C}scribe-review\u{201D}. Open Latch to watch it work."
        )
    }

    func testAnEmptyInstructionBecomesTheDefaultRatherThanNothingToDo() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.agentInstruction = "   \n "

        _ = await viewModel.sendToAgent()

        XCTAssertEqual(dispatcher.requests.first?.instruction, TranscriptAgentRequest.defaultInstruction)
    }

    func testARefusalKeepsTheReasonAndReportsThatNothingWasSent() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        dispatcher.outcome = TranscriptAgentOutcome(
            sessionName: nil,
            agentName: "Claude Code",
            folderName: "Scribe",
            errorMessage: "Latch could not start Claude Code: the manifest was rejected."
        )
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()

        let sent = await viewModel.sendToAgent()

        XCTAssertFalse(sent)
        XCTAssertEqual(viewModel.agentMessage?.isFailure, true)
        XCTAssertEqual(viewModel.agentMessage?.text, "Latch could not start Claude Code: the manifest was rejected.")
        viewModel.dismissAgentMessage()
        XCTAssertNil(viewModel.agentMessage)
    }

    func testTheHostsUnavailableReasonIsWhatTheSheetExplains() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(unavailableReason: "Latch was not found on this Mac.")
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.agentHandoffProblem, "Latch was not found on this Mac.")
        XCTAssertFalse(viewModel.canSubmitAgentHandoff)
        let sent = await viewModel.sendToAgent()
        XCTAssertFalse(sent)
        XCTAssertTrue(dispatcher.requests.isEmpty)
    }

    func testWithNoFolderConnectedTheSheetAsksForOneRatherThanFailingLater() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.agentHandoffProblem, "Connect the folder the agent should work in.")
        XCTAssertFalse(viewModel.canSubmitAgentHandoff)
    }

    func testAFolderThatHasMovedIsNamedRatherThanSilentlyUsed() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.missingFolder])
        let viewModel = TranscriptViewModel(files: [try reviewFile()], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.missingFolder.id)
        XCTAssertEqual(viewModel.agentHandoffProblem, "Gone is no longer where it was. Connect it again.")
        XCTAssertFalse(viewModel.canSubmitAgentHandoff)
    }

    func testAFileWithNoTranscriptHasNothingToSend() async {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let queued = TranscriptReviewFile(
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-agent-queued.flac"),
            transcript: nil,
            jobState: .queued
        )
        let viewModel = TranscriptViewModel(files: [queued], playback: AgentPlaybackStub(), agentDispatcher: dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.agentHandoffProblem, "This file has no completed transcript to send.")
    }

    func testAFolderPathIsShownWithTheHomeDirectoryAbbreviated() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let inside = TranscriptAgentFolder(url: home.appendingPathComponent("Development/Scribe", isDirectory: true))
        XCTAssertEqual(inside.pathDescription, "~/Development/Scribe")
        XCTAssertEqual(inside.displayName, "Scribe")

        let outside = TranscriptAgentFolder(url: URL(fileURLWithPath: "/opt/work/tools"))
        XCTAssertEqual(outside.pathDescription, "/opt/work/tools")
    }

    // MARK: - Fixtures

    private static let claude = TranscriptAgent(id: "claude", displayName: "Claude Code", commandLabel: "claude")
    private static let codex = TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex")
    private static let repository = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/scribe-agent-repository"))
    private static let notes = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Notes"))
    private static let missingFolder = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Gone"), isReachable: false)

    private func reviewFile() throws -> TranscriptReviewFile {
        TranscriptReviewFile(
            sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-agent-snapshot.flac"),
            transcript: try fixture(named: "two-speakers"),
            jobState: .complete
        )
    }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

private final class AgentDispatcherSpy: TranscriptAgentDispatching, @unchecked Sendable {
    var environment = TranscriptAgentEnvironment()
    var outcome: TranscriptAgentOutcome?
    private(set) var requests: [TranscriptAgentRequest] = []

    func environment() async -> TranscriptAgentEnvironment { environment }
    func connectFolder() async -> TranscriptAgentEnvironment { environment }
    func disconnectFolder(id _: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment { environment }

    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        requests.append(request)
        return outcome ?? TranscriptAgentOutcome(
            sessionName: "scribe-review",
            agentName: request.agent.displayName,
            folderName: request.folder.displayName
        )
    }
}

private final class AgentPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}
