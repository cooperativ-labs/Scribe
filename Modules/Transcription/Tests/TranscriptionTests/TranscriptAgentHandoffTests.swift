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
        let viewModel = try makeViewModel(dispatcher)

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
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.selectedAgentID = Self.codex.id

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.selectedAgentID, Self.claude.id)
    }

    func testConnectingAFolderSelectsTheOneThatWasJustConnected() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.repository.id)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.notes, Self.repository])
        await viewModel.connectAgentFolder()

        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.notes.id)
    }

    func testSendingCarriesTheChosenAgentFolderAndInstruction() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository, Self.notes])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.selectedAgentID = Self.codex.id
        viewModel.selectAgentFolder(id: Self.notes.id)
        viewModel.agentInstruction = "  Turn the action items into issues.  "

        let sent = await viewModel.sendToAgent()

        XCTAssertTrue(sent)
        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.agent.id, Self.codex.id)
        XCTAssertEqual(request.folder?.id, Self.notes.id)
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
        let viewModel = try makeViewModel(dispatcher)
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
        let viewModel = try makeViewModel(dispatcher)
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
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertEqual(viewModel.agentHandoffProblem, "Latch was not found on this Mac.")
        XCTAssertFalse(viewModel.canSubmitAgentHandoff)
        let sent = await viewModel.sendToAgent()
        XCTAssertFalse(sent)
        XCTAssertTrue(dispatcher.requests.isEmpty)
    }

    func testTheInstructionStartsAsTheEditableDefault() async throws {
        let viewModel = try makeViewModel(AgentDispatcherSpy())

        XCTAssertEqual(viewModel.agentInstruction, TranscriptAgentRequest.defaultInstruction)
        XCTAssertEqual(
            TranscriptAgentRequest.defaultInstruction,
            "Review this transcript and create meeting notes in the Tough Leaf workspace in the Knowledgebase."
        )
    }

    func testWithNoFolderConnectedTheAgentIsSentWithoutOne() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()

        XCTAssertNil(viewModel.agentHandoffProblem)
        let sent = await viewModel.sendToAgent()

        XCTAssertTrue(sent)
        XCTAssertNil(try XCTUnwrap(dispatcher.requests.first).folder)
        XCTAssertEqual(
            viewModel.agentMessage?.text,
            "Sent to Claude Code as \u{201C}scribe-review\u{201D}. Open Latch to watch it work."
        )
    }

    func testChoosingNoFolderSurvivesARefresh() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        XCTAssertEqual(viewModel.selectedAgentFolderID, Self.repository.id)

        viewModel.selectAgentFolder(id: nil)
        await viewModel.loadAgentEnvironment()

        XCTAssertNil(viewModel.selectedAgentFolderID)
        XCTAssertNil(viewModel.agentHandoffProblem)
    }

    func testSendingCarriesTheModelEffortAndMCPURL() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.gemini], folders: [])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.agentModel = " opus "
        viewModel.agentEffort = .xhigh
        viewModel.agentMCPURL = " https://kb.example.com/mcp "

        _ = await viewModel.sendToAgent()

        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.model, "opus")
        XCTAssertEqual(request.effort, .xhigh)
        XCTAssertEqual(request.mcpURL, "https://kb.example.com/mcp")

        // An agent with no effort setting is never sent one, whatever the
        // picker last held.
        viewModel.selectedAgentID = Self.gemini.id
        viewModel.agentEffort = .high
        viewModel.agentModel = ""
        _ = await viewModel.sendToAgent()
        let second = try XCTUnwrap(dispatcher.requests.last)
        XCTAssertNil(second.effort)
        XCTAssertNil(second.model)
    }

    func testAnMCPURLThatIsNotOneIsNamedBeforeSending() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()
        viewModel.agentMCPURL = "knowledgebase"

        XCTAssertEqual(viewModel.agentHandoffProblem, "The MCP URL should start with http:// or https://.")
        XCTAssertFalse(viewModel.canSubmitAgentHandoff)
    }

    func testEachAgentKeepsItsOwnModelHistoryAndStartsOnTheLastOneUsed() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [])
        let viewModel = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment()

        for model in ["opus", "sonnet", "opus"] {
            viewModel.agentModel = model
            viewModel.agentEffort = .high
            _ = await viewModel.sendToAgent()
        }
        XCTAssertEqual(viewModel.agentModelHistory, ["opus", "sonnet"])

        viewModel.selectedAgentID = Self.codex.id
        XCTAssertEqual(viewModel.agentModel, "")
        XCTAssertNil(viewModel.agentEffort)
        XCTAssertEqual(viewModel.agentModelHistory, [])
        viewModel.agentModel = "gpt-5.5"
        _ = await viewModel.sendToAgent()

        // A later window starts on the agent, model, and effort last sent, and
        // going back to the other agent brings its own choices with it.
        let later = try makeViewModel(dispatcher)
        await later.loadAgentEnvironment()
        XCTAssertEqual(later.selectedAgentID, Self.codex.id)
        XCTAssertEqual(later.agentModel, "gpt-5.5")
        later.selectedAgentID = Self.claude.id
        XCTAssertEqual(later.agentModel, "opus")
        XCTAssertEqual(later.agentEffort, .high)
    }

    func testTheModelHistoryKeepsTheTenMostRecentUniqueNames() {
        for index in 1...12 {
            preferences.recordSend(agentID: "claude", model: "model-\(index)", effort: nil)
        }
        preferences.recordSend(agentID: "claude", model: "model-5", effort: nil)
        preferences.recordSend(agentID: "claude", model: "", effort: nil)

        let history = preferences.modelHistory(for: "claude")
        XCTAssertEqual(history.count, 10)
        XCTAssertEqual(Array(history.prefix(2)), ["model-5", "model-12"])
        XCTAssertEqual(Set(history).count, 10)
        // Clearing the field is remembered as the last choice without
        // becoming a name in the list.
        XCTAssertEqual(preferences.lastModel(for: "claude"), "")
    }

    func testAFolderThatHasMovedIsNamedRatherThanSilentlyUsed() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.missingFolder])
        let viewModel = try makeViewModel(dispatcher)
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
        let viewModel = TranscriptViewModel(files: [queued], playback: AgentPlaybackStub(), agentDispatcher: dispatcher, agentPreferences: preferences)
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

    private static let claude = TranscriptAgent(id: "claude", displayName: "Claude Code", commandLabel: "claude", supportsEffort: true)
    private static let codex = TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex", supportsEffort: true)
    private static let gemini = TranscriptAgent(id: "gemini", displayName: "Gemini CLI", commandLabel: "gemini")
    private static let repository = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/scribe-agent-repository"))
    private static let notes = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Notes"))
    private static let missingFolder = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Gone"), isReachable: false)

    /// Every test gets defaults of its own: what one sending remembers must
    /// not decide where the next test's sheet starts.
    private let defaultsSuite = "TranscriptAgentHandoffTests-\(UUID().uuidString)"
    private lazy var preferences = TranscriptAgentPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeViewModel(_ dispatcher: AgentDispatcherSpy) throws -> TranscriptViewModel {
        TranscriptViewModel(
            files: [try reviewFile()],
            playback: AgentPlaybackStub(),
            agentDispatcher: dispatcher,
            agentPreferences: preferences
        )
    }

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
            folderName: request.folder?.displayName
        )
    }
}

private final class AgentPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}
