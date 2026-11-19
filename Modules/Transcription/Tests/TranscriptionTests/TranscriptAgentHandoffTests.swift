import Foundation
import XCTest
@testable import Transcription

/// The handoff tray's behaviour through the view model: every call names the
/// tray it is for, so these tests drive a row with no draft (an import or a
/// pasted transcript) and meetings with drafts side by side.
@MainActor
final class TranscriptAgentHandoffTests: XCTestCase {
    func testWithoutAHostDispatcherTheActionIsNotOffered() async throws {
        let file = try reviewFile()
        let viewModel = TranscriptViewModel(files: [file], playback: AgentPlaybackStub())
        let target = viewModel.handoffTarget(for: file)

        XCTAssertFalse(viewModel.canSendToAgent)
        await viewModel.loadAgentEnvironment(for: target)
        XCTAssertNil(viewModel.agentEnvironment)
        // A keyboard route could still reach the model; it must be inert.
        let sent = await viewModel.sendToAgent(target)
        XCTAssertFalse(sent)
        XCTAssertNil(viewModel.handoffStatus(for: target))
    }

    // MARK: - Imports and pasted transcripts: no notes, immediate send

    func testARowWithNoDraftHasNoNotesAndSendsImmediately() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository, Self.notes])
        let (viewModel, target) = try makeViewModel(dispatcher)
        XCTAssertEqual(target, .transcript(viewModel.files[0].id))
        XCTAssertNil(viewModel.handoffNotes(for: target), "imports and pasted transcripts get no notes area")

        await viewModel.loadAgentEnvironment(for: target)
        viewModel.selectHandoffAgent(Self.codex.id, for: target)
        viewModel.selectHandoffFolder(.folder(Self.notes.id), for: target)
        viewModel.setHandoffPrompt("  Turn the action items into issues.  ", for: target)

        let sent = await viewModel.sendToAgent(target)

        XCTAssertTrue(sent)
        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.agent.id, Self.codex.id)
        XCTAssertEqual(request.folder?.id, Self.notes.id)
        XCTAssertEqual(request.instruction, "Turn the action items into issues.")
        XCTAssertEqual(request.notes, [])
        XCTAssertEqual(request.transcript.transcriptID, try fixture(named: "two-speakers").transcriptID)
        guard case .sent(let outcome)? = viewModel.handoffStatus(for: target) else {
            return XCTFail("the tray shows Sent")
        }
        XCTAssertEqual(outcome.sentDescription, "Sent to Codex in Notes")
        XCTAssertEqual(outcome.sessionID, "session-1")
    }

    func testLoadingTakesTheLastAgentElseTheFirstAndTheFirstFolderThatIsStillThere() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.missingFolder, Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)

        XCTAssertTrue(viewModel.canSendToAgent)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffAgent(for: target)?.id, Self.claude.id)
        // Unset resolves to the first folder that can actually be sent to.
        XCTAssertEqual(viewModel.handoffSettings(for: target).folder, .unset)
        XCTAssertEqual(viewModel.handoffFolder(for: target)?.id, Self.repository.id)
        XCTAssertNil(viewModel.handoffProblem(for: target))
        XCTAssertTrue(viewModel.canSubmitHandoff(target))

        preferences.recordSend(agentID: Self.codex.id, model: "gpt-5.5", effort: .high)
        let (later, laterTarget) = try makeViewModel(dispatcher)
        await later.loadAgentEnvironment(for: laterTarget)
        XCTAssertEqual(later.handoffAgent(for: laterTarget)?.id, Self.codex.id)
        XCTAssertEqual(later.handoffSettings(for: laterTarget).model, "gpt-5.5")
        XCTAssertEqual(later.handoffEffort(for: laterTarget), .high)
    }

    func testAnAgentThatIsGoneIsNamedRatherThanSilentlyReplaced() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.selectHandoffAgent(Self.codex.id, for: target)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertNil(viewModel.handoffAgent(for: target))
        XCTAssertEqual(viewModel.handoffProblem(for: target), "codex is not installed on this Mac. Choose another agent.")
        XCTAssertFalse(viewModel.canSubmitHandoff(target))
        viewModel.selectHandoffAgent(Self.claude.id, for: target)
        XCTAssertNil(viewModel.handoffProblem(for: target))
    }

    // MARK: - Folder: unset, No folder, a folder

    func testConnectingAFolderPointsThisTrayAtIt() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        XCTAssertEqual(viewModel.handoffFolder(for: target)?.id, Self.repository.id)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.notes, Self.repository])
        await viewModel.connectAgentFolder(for: target)

        XCTAssertEqual(viewModel.handoffSettings(for: target).folder, .folder(Self.notes.id))
        XCTAssertEqual(viewModel.handoffFolder(for: target)?.id, Self.notes.id)
    }

    func testNoFolderIsAChoiceThatSurvivesARefreshAndIsSentWithoutOne() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        viewModel.selectHandoffFolder(.none, for: target)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffSettings(for: target).folder, MeetingHandoffFolder.none)
        XCTAssertNil(viewModel.handoffFolder(for: target))
        XCTAssertNil(viewModel.handoffProblem(for: target))
        _ = await viewModel.sendToAgent(target)
        XCTAssertNil(try XCTUnwrap(dispatcher.requests.first).folder)
    }

    func testWithNoFolderConnectedUnsetSendsWithoutOne() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffDestinationSummary(for: target), "Claude Code \u{00B7} no folder")
        let sent = await viewModel.sendToAgent(target)

        XCTAssertTrue(sent)
        XCTAssertNil(try XCTUnwrap(dispatcher.requests.first).folder)
    }

    func testAnExplicitFolderThatIsNoLongerConnectedIsReportedNotReplaced() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository, Self.notes])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.selectHandoffFolder(.folder(Self.notes.id), for: target)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertTrue(viewModel.handoffFolderIsMissing(for: target))
        XCTAssertNil(viewModel.handoffFolder(for: target))
        XCTAssertEqual(viewModel.handoffProblem(for: target), "The folder chosen for this is no longer connected. Choose a folder, or No Folder.")
        XCTAssertTrue(viewModel.handoffDestinationSummary(for: target).hasSuffix("folder missing"))
    }

    func testDisconnectingThisTraysFolderReturnsItToTheDefault() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository, Self.notes])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.selectHandoffFolder(.folder(Self.notes.id), for: target)

        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        await viewModel.disconnectAgentFolder(id: Self.notes.id, for: target)

        XCTAssertEqual(viewModel.handoffSettings(for: target).folder, .unset)
        XCTAssertEqual(viewModel.handoffFolder(for: target)?.id, Self.repository.id)
        XCTAssertEqual(dispatcher.disconnected, [Self.notes.id])
    }

    func testAFolderThatHasMovedIsNamedRatherThanSilentlyUsed() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.missingFolder])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffFolder(for: target)?.id, Self.missingFolder.id)
        XCTAssertEqual(viewModel.handoffProblem(for: target), "Gone is no longer where it was. Connect it again.")
        XCTAssertFalse(viewModel.canSubmitHandoff(target))
    }

    // MARK: - Model and effort

    func testSendingCarriesTheModelEffortAndMCPURLAndAnAgentWithoutEffortNeverGetsOne() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.gemini], folders: [])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.setHandoffModel(" opus ", for: target)
        viewModel.setHandoffEffort(.xhigh, for: target)
        viewModel.setHandoffMCPURL(" https://kb.example.com/mcp ", for: target)

        _ = await viewModel.sendToAgent(target)

        let request = try XCTUnwrap(dispatcher.requests.first)
        XCTAssertEqual(request.model, "opus")
        XCTAssertEqual(request.effort, .xhigh)
        XCTAssertEqual(request.mcpURL, "https://kb.example.com/mcp")

        // Gemini takes no effort: the tray hides the pill and the request
        // never carries one, whatever the settings last held.
        viewModel.selectHandoffAgent(Self.gemini.id, for: target)
        viewModel.updateHandoff(target) { $0.effort = TranscriptAgentEffort.high.rawValue }
        XCTAssertNil(viewModel.handoffEffort(for: target))
        XCTAssertFalse(viewModel.handoffDestinationSummary(for: target).contains("effort"))
        _ = await viewModel.sendToAgent(target)
        let second = try XCTUnwrap(dispatcher.requests.last)
        XCTAssertNil(second.effort)
        XCTAssertNil(second.model)
    }

    func testAnMCPURLThatIsNotOneIsNamedBeforeSending() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.setHandoffMCPURL("knowledgebase", for: target)

        XCTAssertEqual(viewModel.handoffProblem(for: target), "The MCP URL should start with http:// or https://.")
        XCTAssertFalse(viewModel.canSubmitHandoff(target))
    }

    func testModelAndEffortAreScopedPerAgent() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        for model in ["opus", "sonnet", "opus"] {
            viewModel.setHandoffModel(model, for: target)
            viewModel.setHandoffEffort(.high, for: target)
            _ = await viewModel.sendToAgent(target)
        }
        XCTAssertEqual(viewModel.handoffModelHistory(for: target), ["opus", "sonnet"])

        viewModel.selectHandoffAgent(Self.codex.id, for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).model, "")
        XCTAssertNil(viewModel.handoffEffort(for: target))
        XCTAssertEqual(viewModel.handoffModelHistory(for: target), [])

        viewModel.selectHandoffAgent(Self.claude.id, for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).model, "opus")
        XCTAssertEqual(viewModel.handoffEffort(for: target), .high)
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

    // MARK: - Prompt origin and folder swap

    func testAnUneditedPromptFollowsTheFolderAndAnEditedOneStays() async throws {
        preferences.recordInstruction("File the bugs.", folderID: Self.repository.id)
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository, Self.notes])
        let (viewModel, target) = try makeViewModel(dispatcher)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, TranscriptAgentRequest.defaultInstruction)

        // Unset resolves to Repository, whose last prompt takes over.
        await viewModel.loadAgentEnvironment(for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, "File the bugs.")
        XCTAssertEqual(viewModel.handoffSettings(for: target).promptOrigin, .folderHistory)

        // A folder with no history brings the default back.
        viewModel.selectHandoffFolder(.folder(Self.notes.id), for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, TranscriptAgentRequest.defaultInstruction)
        XCTAssertEqual(viewModel.handoffSettings(for: target).promptOrigin, .default)

        // Words the person typed are never swapped out.
        viewModel.setHandoffPrompt("Summarise the decisions only.", for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).promptOrigin, .edited)
        viewModel.selectHandoffFolder(.folder(Self.repository.id), for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, "Summarise the decisions only.")

        // A prompt chosen from Recent is a choice too; resetting hands the
        // prompt back to the folder.
        viewModel.chooseRecentPrompt("File the bugs.", for: target)
        viewModel.selectHandoffFolder(.none, for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, "File the bugs.")
        viewModel.resetHandoffPrompt(for: target)
        XCTAssertEqual(viewModel.handoffSettings(for: target).prompt, TranscriptAgentRequest.defaultInstruction)
        XCTAssertNotEqual(viewModel.handoffSettings(for: target).promptOrigin, .edited)
    }

    func testAnEmptyPromptBecomesTheDefaultRatherThanNothingToDo() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.setHandoffPrompt("   \n ", for: target)

        _ = await viewModel.sendToAgent(target)

        XCTAssertEqual(dispatcher.requests.first?.instruction, TranscriptAgentRequest.defaultInstruction)
    }

    // MARK: - History only after a confirmed send

    func testHistoryIsWrittenOnlyAfterLatchConfirmsTheSend() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude, Self.codex], folders: [Self.repository, Self.notes])
        dispatcher.outcome = TranscriptAgentOutcome(sessionName: nil, agentName: "Codex", folderName: "Notes", errorMessage: "Latch could not start Codex: the manifest was rejected.")
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)
        viewModel.selectHandoffAgent(Self.codex.id, for: target)
        viewModel.setHandoffModel("gpt-5.5", for: target)
        viewModel.setHandoffMCPURL("https://kb.example.com/mcp", for: target)
        viewModel.setHandoffPrompt("Never sent.", for: target)

        let refused = await viewModel.sendToAgent(target)

        XCTAssertFalse(refused)
        XCTAssertEqual(viewModel.handoffStatus(for: target), .failed("Latch could not start Codex: the manifest was rejected."))
        XCTAssertNil(preferences.lastAgentID)
        XCTAssertEqual(preferences.modelHistory(for: Self.codex.id), [])
        XCTAssertEqual(preferences.mcpURL, "")
        XCTAssertEqual(preferences.instructionHistory(forFolder: Self.repository.id), [])

        // Try again, and this time Latch creates the session.
        dispatcher.outcome = nil
        let sent = await viewModel.sendToAgent(target)

        XCTAssertTrue(sent)
        XCTAssertEqual(preferences.lastAgentID, Self.codex.id)
        XCTAssertEqual(preferences.modelHistory(for: Self.codex.id), ["gpt-5.5"])
        XCTAssertEqual(preferences.mcpURL, "https://kb.example.com/mcp")
        XCTAssertEqual(preferences.instructionHistory(forFolder: Self.repository.id), ["Never sent."])
        XCTAssertEqual(preferences.instructionHistory(forFolder: Self.notes.id), [])
        // Every press is its own operation.
        XCTAssertEqual(Set(dispatcher.requests.map(\.operationID)).count, 2)
    }

    func testTheInstructionHistoryKeepsTheTenMostRecent() {
        for number in 1...12 {
            preferences.recordInstruction("Instruction \(number)", folderID: Self.repository.id)
        }
        preferences.recordInstruction("   ", folderID: Self.repository.id)
        preferences.recordInstruction("Elsewhere", folderID: nil)

        let history = preferences.instructionHistory(forFolder: Self.repository.id)
        XCTAssertEqual(history.count, TranscriptAgentPreferences.instructionHistoryLimit)
        XCTAssertEqual(history.first, "Instruction 12")
        XCTAssertEqual(history.last, "Instruction 3")
        XCTAssertEqual(preferences.instructionHistory(forFolder: nil), ["Elsewhere"])
    }

    // MARK: - Tray states

    func testSentOffersOpenInLatchAndSendAgainMakesANewOperation() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(agents: [Self.claude], folders: [Self.repository])
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        _ = await viewModel.sendToAgent(target)
        await viewModel.openHandoffSession(for: target)
        XCTAssertEqual(dispatcher.opened, ["session-1"])

        _ = await viewModel.sendToAgent(target)
        XCTAssertEqual(dispatcher.requests.count, 2)
        XCTAssertNotEqual(dispatcher.requests[0].operationID, dispatcher.requests[1].operationID)
    }

    func testTheHostsUnavailableReasonIsWhatTheTrayExplains() async throws {
        let dispatcher = AgentDispatcherSpy()
        dispatcher.environment = TranscriptAgentEnvironment(unavailableReason: "Latch was not found on this Mac.")
        let (viewModel, target) = try makeViewModel(dispatcher)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffProblem(for: target), "Latch was not found on this Mac.")
        XCTAssertFalse(viewModel.canSubmitHandoff(target))
        let sent = await viewModel.sendToAgent(target)
        XCTAssertFalse(sent)
        XCTAssertTrue(dispatcher.requests.isEmpty)
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
        let target = viewModel.handoffTarget(for: queued)
        await viewModel.loadAgentEnvironment(for: target)

        XCTAssertEqual(viewModel.handoffProblem(for: target), "The transcript isn\u{2019}t ready yet.")
    }

    func testTheDefaultPromptIsUnchanged() {
        XCTAssertEqual(
            TranscriptAgentRequest.defaultInstruction,
            "Review this transcript and create meeting notes in the Tough Leaf workspace in the Knowledgebase."
        )
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

    nonisolated static let claude = TranscriptAgent(id: "claude", displayName: "Claude Code", commandLabel: "claude", supportsEffort: true)
    nonisolated static let codex = TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex", supportsEffort: true)
    nonisolated static let gemini = TranscriptAgent(id: "gemini", displayName: "Gemini CLI", commandLabel: "gemini")
    nonisolated static let repository = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/scribe-agent-repository"))
    nonisolated static let notes = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Notes"))
    nonisolated static let missingFolder = TranscriptAgentFolder(url: URL(fileURLWithPath: "/tmp/Gone"), isReachable: false)

    /// Every test gets defaults of its own: what one sending remembers must
    /// not decide where the next test's tray starts.
    private let defaultsSuite = "TranscriptAgentHandoffTests-\(UUID().uuidString)"
    private lazy var preferences = TranscriptAgentPreferences(defaults: UserDefaults(suiteName: defaultsSuite)!)

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        super.tearDown()
    }

    private func makeViewModel(_ dispatcher: AgentDispatcherSpy) throws -> (TranscriptViewModel, AgentHandoffTarget) {
        let file = try reviewFile()
        let viewModel = TranscriptViewModel(
            files: [file],
            playback: AgentPlaybackStub(),
            agentDispatcher: dispatcher,
            agentPreferences: preferences
        )
        return (viewModel, viewModel.handoffTarget(for: file))
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

final class AgentDispatcherSpy: TranscriptAgentDispatching, @unchecked Sendable {
    var environment = TranscriptAgentEnvironment()
    var outcome: TranscriptAgentOutcome?
    private(set) var requests: [TranscriptAgentRequest] = []
    private(set) var opened: [String] = []
    private(set) var disconnected: [String] = []

    func environment() async -> TranscriptAgentEnvironment { environment }
    func connectFolder() async -> TranscriptAgentEnvironment { environment }
    func disconnectFolder(id: TranscriptAgentFolder.ID) async -> TranscriptAgentEnvironment {
        disconnected.append(id)
        return environment
    }

    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        requests.append(request)
        return outcome ?? TranscriptAgentOutcome(
            sessionName: "scribe-review",
            sessionID: "session-\(requests.count)",
            agentName: request.agent.displayName,
            folderName: request.folder?.displayName
        )
    }

    func openSession(id: String) async -> String? {
        opened.append(id)
        return nil
    }
}

final class AgentPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}
