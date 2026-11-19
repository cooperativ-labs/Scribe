import Foundation

/// Sending a transcript, its notes and a prompt to a coding agent.
///
/// Every call names the tray it is for (`AgentHandoffTarget`), captured when
/// the tray was drawn: a meeting's settings are its draft's, a row with no
/// draft has its own, and nothing is read from "the selected row" after an
/// await. The installed agents and connected folders are machine facts and
/// the only thing all trays share.
public extension TranscriptViewModel {
    /// Whether the window offers sending at all. Without a host dispatcher
    /// there is nothing to send to, so no tray or toolbar action is shown.
    var canSendToAgent: Bool { agentDispatcher != nil }

    var agents: [TranscriptAgent] { agentEnvironment?.agents ?? [] }
    var agentFolders: [TranscriptAgentFolder] { agentEnvironment?.folders ?? [] }

    /// The tray a row gets: its meeting draft's, or its own.
    func handoffTarget(for file: TranscriptReviewFile) -> AgentHandoffTarget {
        if let draft = file.draft { return .draft(draft.id) }
        return .transcript(file.id)
    }

    /// The row a tray belongs to, wherever it is in the list now.
    func handoffFile(for target: AgentHandoffTarget) -> TranscriptReviewFile? {
        switch target {
        case .draft(let id): files.first { $0.draft?.id == id }
        case .transcript(let id): files.first { $0.id == id && $0.draft == nil }
        }
    }

    // MARK: - Settings

    /// What the tray shows. A meeting's settings come from its draft, seeded
    /// once when recording started; a row with no draft is seeded from the
    /// remembered preferences the first time it is asked for.
    func handoffSettings(for target: AgentHandoffTarget) -> MeetingHandoffSettings {
        _ = handoffRevision
        switch target {
        case .draft(let id):
            return draftEditor?.handoffSettings(draftID: id) ?? MeetingHandoffSettings()
        case .transcript(let id):
            return transcriptHandoffs[id] ?? MeetingHandoffSettings(seededFrom: agentPreferences)
        }
    }

    /// Changes one tray's settings and nothing else's.
    func updateHandoff(_ target: AgentHandoffTarget, _ change: (inout MeetingHandoffSettings) -> Void) {
        var settings = handoffSettings(for: target)
        let before = settings
        change(&settings)
        guard settings != before else { return }
        switch target {
        case .draft(let id):
            guard let draftEditor else { return }
            draftEditor.setHandoffSettings(draftID: id, settings)
            handoffRevision &+= 1
        case .transcript(let id):
            transcriptHandoffs[id] = settings
        }
    }

    /// The agent the tray names, if it is installed. Before the host has
    /// answered, or when the named agent is gone, this is nil.
    func handoffAgent(for target: AgentHandoffTarget) -> TranscriptAgent? {
        guard let agentID = handoffSettings(for: target).agentID else { return nil }
        return agents.first { $0.id == agentID }
    }

    /// The effort to send, or nil for the agent's own (and always nil for an
    /// agent that takes none).
    func handoffEffort(for target: AgentHandoffTarget) -> TranscriptAgentEffort? {
        guard handoffAgent(for: target)?.supportsEffort == true else { return nil }
        return handoffSettings(for: target).effort.flatMap(TranscriptAgentEffort.init(rawValue:))
    }

    /// Where the agent will work. `unset` means the default: the first
    /// connected folder that is still there, else the first connected one,
    /// else none. A folder named explicitly but no longer connected resolves
    /// to nil and is reported by `handoffProblem`, never silently replaced.
    func handoffFolder(for target: AgentHandoffTarget) -> TranscriptAgentFolder? {
        switch handoffSettings(for: target).folder {
        case .unset: agentFolders.first(where: \.isReachable) ?? agentFolders.first
        case .none: nil
        case .folder(let id): agentFolders.first { $0.id == id }
        }
    }

    /// True when the tray names a folder that is no longer connected.
    func handoffFolderIsMissing(for target: AgentHandoffTarget) -> Bool {
        guard agentEnvironment != nil, case .folder(let id) = handoffSettings(for: target).folder else { return false }
        return !agentFolders.contains { $0.id == id }
    }

    /// Picks the agent. Model and effort follow it: each agent starts on what
    /// it was last sent with, because model names mean nothing to another.
    func selectHandoffAgent(_ agentID: TranscriptAgent.ID, for target: AgentHandoffTarget) {
        updateHandoff(target) { settings in
            guard settings.agentID != agentID else { return }
            settings.agentID = agentID
            settings.model = agentPreferences.lastModel(for: agentID)
            settings.effort = agentPreferences.effort(for: agentID)?.rawValue
        }
    }

    func setHandoffModel(_ model: String, for target: AgentHandoffTarget) {
        updateHandoff(target) { $0.model = model }
    }

    func setHandoffEffort(_ effort: TranscriptAgentEffort?, for target: AgentHandoffTarget) {
        updateHandoff(target) { $0.effort = effort?.rawValue }
    }

    func setHandoffMCPURL(_ url: String, for target: AgentHandoffTarget) {
        updateHandoff(target) { $0.mcpURL = url }
    }

    /// Picks the folder, or "No folder" with `.none`. The prompt follows the
    /// folder (its last prompt, else the default) unless the person wrote
    /// or chose the prompt themselves.
    func selectHandoffFolder(_ folder: MeetingHandoffFolder, for target: AgentHandoffTarget) {
        updateHandoff(target) { $0.folder = folder }
        followFolderWithPrompt(target)
    }

    /// The person typed in the prompt: from now on a folder change leaves it.
    func setHandoffPrompt(_ prompt: String, for target: AgentHandoffTarget) {
        updateHandoff(target) { settings in
            guard settings.prompt != prompt else { return }
            settings.prompt = prompt
            settings.promptOrigin = .edited
        }
    }

    /// A prompt chosen from the folder's history is the person's choice, kept
    /// like one they typed.
    func chooseRecentPrompt(_ prompt: String, for target: AgentHandoffTarget) {
        updateHandoff(target) { settings in
            settings.prompt = prompt
            settings.promptOrigin = .edited
        }
    }

    /// Gives the prompt back to the folder: its last prompt, else the default.
    func resetHandoffPrompt(for target: AgentHandoffTarget) {
        updateHandoff(target) { $0.promptOrigin = .default }
        followFolderWithPrompt(target)
    }

    /// The prompt a folder starts with: the last one sent into it, else the
    /// default.
    func folderPrompt(forFolderID folderID: TranscriptAgentFolder.ID?) -> (prompt: String, origin: MeetingPromptOrigin) {
        if let last = agentPreferences.instructionHistory(forFolder: folderID).first {
            return (last, .folderHistory)
        }
        return (TranscriptAgentRequest.defaultInstruction, .default)
    }

    /// The models typed for this tray's agent before, most recent first.
    func handoffModelHistory(for target: AgentHandoffTarget) -> [String] {
        handoffSettings(for: target).agentID.map(agentPreferences.modelHistory(for:)) ?? []
    }

    /// The prompts sent into this tray's folder, most recent first.
    func handoffPromptHistory(for target: AgentHandoffTarget) -> [String] {
        agentPreferences.instructionHistory(forFolder: handoffFolder(for: target)?.id)
    }

    /// "Claude Code · opus · tough-leaf": where this tray sends, as it stands.
    func handoffDestinationSummary(for target: AgentHandoffTarget) -> String {
        let settings = handoffSettings(for: target)
        var parts: [String] = []
        if let agent = handoffAgent(for: target) {
            parts.append(agent.displayName)
        } else if agentEnvironment == nil {
            parts.append("Agent")
        } else {
            parts.append("No agent")
        }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { parts.append(model) }
        if let effort = handoffEffort(for: target) { parts.append(effort.trayLabel) }
        if handoffFolderIsMissing(for: target) {
            parts.append("folder missing")
        } else if let folder = handoffFolder(for: target) {
            parts.append(folder.displayName)
        } else if agentEnvironment != nil {
            parts.append("no folder")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The notes this tray sends, or nil for a row with no notes area
    /// (imports and pasted transcripts, decision 11).
    func handoffNotes(for target: AgentHandoffTarget) -> MeetingNotesContent? {
        guard case .draft(let id) = target, let draftEditor else { return nil }
        return draftEditor.notes(draftID: id)
    }

    // MARK: - Sending

    /// Why this tray cannot send yet, in the person's terms, or nil when
    /// everything it needs is chosen.
    func handoffProblem(for target: AgentHandoffTarget) -> String? {
        if let reason = agentEnvironment?.unavailableReason { return reason }
        guard let file = handoffFile(for: target) else { return "This transcript is no longer in the list." }
        if file.draft?.isOrphaned == true { return "There is no transcript to send: the recording for these notes is gone." }
        if file.transcript == nil { return "The transcript isn\u{2019}t ready yet." }
        return handoffSettingsProblem(for: target)
    }

    /// What is wrong with the tray's choices, whether or not the transcript
    /// is ready: what must be fixed before a send can be queued.
    func handoffSettingsProblem(for target: AgentHandoffTarget) -> String? {
        if let reason = agentEnvironment?.unavailableReason { return reason }
        guard agentEnvironment != nil else { return "Looking for agents\u{2026}" }
        if agents.isEmpty { return "No coding agent was found on this Mac." }
        let settings = handoffSettings(for: target)
        if handoffAgent(for: target) == nil {
            if let agentID = settings.agentID { return "\(agentID) is not installed on this Mac. Choose another agent." }
            return "Choose an agent."
        }
        if handoffFolderIsMissing(for: target) {
            return "The folder chosen for this is no longer connected. Choose a folder, or No Folder."
        }
        if let folder = handoffFolder(for: target), !folder.isReachable {
            return "\(folder.displayName) is no longer where it was. Connect it again."
        }
        if !Self.isAcceptableMCPURL(settings.mcpURL) { return "The MCP URL should start with http:// or https://." }
        if case .unavailable = handoffNotes(for: target) {
            return "These notes can\u{2019}t be read, so they can\u{2019}t be sent."
        }
        return nil
    }

    func handoffStatus(for target: AgentHandoffTarget) -> AgentHandoffSendStatus? {
        handoffStatuses[target]
    }

    func canSubmitHandoff(_ target: AgentHandoffTarget) -> Bool {
        handoffProblem(for: target) == nil && handoffStatuses[target] != .sending && !hasLiveQueuedSend(target)
    }

    // MARK: - Send after processing

    /// The meeting's queued send, or nil for a row with no draft.
    func queuedSend(for target: AgentHandoffTarget) -> MeetingSend? {
        guard case .draft = target else { return nil }
        return handoffFile(for: target)?.draft?.send
    }

    /// A queued send that is not finished: while there is one, sending by
    /// hand would be a second send of the same meeting.
    private func hasLiveQueuedSend(_ target: AgentHandoffTarget) -> Bool {
        queuedSend(for: target)?.blocksCombine == true
    }

    /// Whether the tray offers "Send after processing": a recorded meeting
    /// whose transcript is not ready yet, with nothing already queued.
    func canQueueSend(_ target: AgentHandoffTarget) -> Bool {
        guard sendController != nil, agentDispatcher != nil, case .draft = target,
              let file = handoffFile(for: target), file.transcript == nil,
              let draft = file.draft, !draft.isOrphaned,
              handoffStatuses[target] != .sending else { return false }
        switch draft.send {
        case .notQueued, .sent: return true
        case .failed(_, _, let definite, _): return definite
        case .queued, .held, .claimed: return false
        }
    }

    /// What the tray's send controls show: a send made by hand in this
    /// window, else the meeting's queued send, else what can be done next.
    func handoffTrayState(for target: AgentHandoffTarget) -> AgentHandoffTrayState {
        if let status = handoffStatuses[target] { return .manual(status) }
        switch queuedSend(for: target) {
        case .queued?:
            return .waiting
        case .held(_, let reason, _)?:
            return .held(reason)
        case .claimed?:
            return .manual(.sending)
        case let .sent(_, sessionID, sessionName, destination, _)?:
            return .manual(.sent(TranscriptAgentOutcome(
                sessionName: sessionName,
                sessionID: sessionID.isEmpty ? nil : sessionID,
                agentName: destination,
                folderName: nil
            )))
        case let .failed(_, message, definite, _)?:
            return definite ? .manual(.failed(message)) : .unconfirmed(message)
        case .notQueued?, nil:
            return canQueueSend(target) ? .canQueue : .manual(nil)
        }
    }

    /// "Send after processing": queues this meeting's send. The settings
    /// stay editable; the send uses what the tray holds when it fires.
    func queueSend(_ target: AgentHandoffTarget) async {
        guard let sendController, let draftID = target.draftID, canQueueSend(target),
              handoffSettingsProblem(for: target) == nil else { return }
        handoffStatuses[target] = nil
        if let failure = await sendController.queueSend(draftID: draftID) {
            toastCenter.post(failure, kind: .failure)
        }
    }

    func cancelQueuedSend(_ target: AgentHandoffTarget) async {
        guard let sendController, let draftID = target.draftID else { return }
        if let failure = await sendController.cancelSend(draftID: draftID, operationID: queuedSend(for: target)?.operationID) {
            toastCenter.post(failure, kind: .failure)
        }
    }

    /// "Send" on a held send: the person confirmed, so Latch comes forward.
    func confirmHeldSend(_ target: AgentHandoffTarget) async {
        guard let sendController, let draftID = target.draftID else { return }
        await sendController.confirmSend(draftID: draftID, operationID: queuedSend(for: target)?.operationID, interactive: true)
    }

    /// "Try again" on a send whose outcome is unknown: the same send again,
    /// which Latch answers with the session it already started, if any.
    func retryUnconfirmedSend(_ target: AgentHandoffTarget) async {
        guard let sendController, let draftID = target.draftID else { return }
        await sendController.retrySend(draftID: draftID)
    }

    /// Gives up on a send whose outcome is unknown, so the meeting can be
    /// sent or combined again. The person is told to check Latch first.
    func dismissUnconfirmedSend(_ target: AgentHandoffTarget) async {
        guard let sendController, let draftID = target.draftID else { return }
        await sendController.clearSendOutcome(draftID: draftID)
    }

    /// Asks the host what is installed and connected, then fills in what
    /// the tray left to defaults. Called each time a tray appears: an agent
    /// can be installed and a folder moved between one send and the next.
    func loadAgentEnvironment(for target: AgentHandoffTarget? = nil) async {
        guard let agentDispatcher else { return }
        agentEnvironment = await agentDispatcher.environment()
        if let target { normalizeHandoff(target) }
    }

    /// Fills in an agent never chosen (the one last sent to, else the first
    /// installed) and lets a prompt the person has not written follow the
    /// folder the tray resolves to. Explicit choices that no longer exist
    /// are left for `handoffProblem` to name.
    func normalizeHandoff(_ target: AgentHandoffTarget) {
        guard let environment = agentEnvironment, handoffFile(for: target) != nil else { return }
        let preferences = agentPreferences
        if handoffSettings(for: target).agentID == nil,
           let agent = environment.agents.first(where: { $0.id == preferences.lastAgentID }) ?? environment.agents.first {
            updateHandoff(target) { settings in
                settings.agentID = agent.id
                settings.model = preferences.lastModel(for: agent.id)
                settings.effort = preferences.effort(for: agent.id)?.rawValue
            }
        }
        if case .transcript(let id) = target, transcriptHandoffs[id] == nil {
            transcriptHandoffs[id] = handoffSettings(for: target)
        }
        followFolderWithPrompt(target)
    }

    /// Sends the person to the host's folder chooser and points this tray at
    /// the folder they connected.
    func connectAgentFolder(for target: AgentHandoffTarget) async {
        guard let agentDispatcher else { return }
        let known = Set(agentFolders.map(\.id))
        let environment = await agentDispatcher.connectFolder()
        agentEnvironment = environment
        if let connected = environment.folders.first(where: { !known.contains($0.id) }) {
            selectHandoffFolder(.folder(connected.id), for: target)
        } else {
            followFolderWithPrompt(target)
        }
    }

    /// Forgets a connected folder. The tray that asked goes back to the
    /// default; other meetings that named it say so before they send.
    func disconnectAgentFolder(id: TranscriptAgentFolder.ID, for target: AgentHandoffTarget) async {
        guard let agentDispatcher else { return }
        agentEnvironment = await agentDispatcher.disconnectFolder(id: id)
        if case .folder(id) = handoffSettings(for: target).folder {
            updateHandoff(target) { $0.folder = .unset }
        }
        followFolderWithPrompt(target)
    }

    /// Sends this tray's transcript, notes and prompt now.
    ///
    /// The target is fixed before the first await; whatever row is selected
    /// meanwhile, the request is built from this tray's row and settings.
    /// Remembered history (agent, model, effort, MCP URL, the prompt for the
    /// folder) is written only once Latch has created the session.
    @discardableResult
    func sendToAgent(_ target: AgentHandoffTarget) async -> Bool {
        guard let agentDispatcher, canSubmitHandoff(target) else { return false }
        handoffStatuses[target] = .sending
        if let draftID = target.draftID {
            // A finished queued send's outcome gives way to this one.
            await sendController?.clearSendOutcome(draftID: draftID)
            await draftEditor?.flushNotes(draftID: draftID)
        }
        // Labels are refreshed first for the same reason exporting refreshes
        // them: the agent should read the names the library holds now.
        if let file = handoffFile(for: target), file.id == selectedFileID {
            await refreshLabelsFromLibrary(announceUnchanged: false)
        }
        guard handoffProblem(for: target) == nil,
              let transcript = handoffFile(for: target)?.transcript,
              let agent = handoffAgent(for: target) else {
            handoffStatuses[target] = handoffProblem(for: target).map(AgentHandoffSendStatus.failed)
            return false
        }
        let settings = handoffSettings(for: target)
        let request = TranscriptAgentRequest(
            transcript: transcript,
            agent: agent,
            model: settings.model,
            effort: handoffEffort(for: target),
            folder: handoffFolder(for: target),
            mcpURL: settings.mcpURL,
            instruction: settings.prompt,
            notes: handoffNotes(for: target)?.notes ?? []
        )
        let outcome = await agentDispatcher.send(request)
        if outcome.succeeded {
            agentPreferences.recordSend(agentID: agent.id, model: request.model, effort: request.effort)
            agentPreferences.mcpURL = request.mcpURL ?? ""
            agentPreferences.recordInstruction(request.instruction, folderID: request.folder?.id)
            handoffStatuses[target] = .sent(outcome)
        } else {
            handoffStatuses[target] = .failed(outcome.summary)
        }
        return outcome.succeeded
    }

    /// Brings the session this tray created back to the front.
    func openHandoffSession(for target: AgentHandoffTarget) async {
        guard let agentDispatcher, case .manual(.sent(let outcome)?) = handoffTrayState(for: target),
              let sessionID = outcome.sessionID else { return }
        if let failure = await agentDispatcher.openSession(id: sessionID) {
            toastCenter.post(failure, kind: .failure)
        }
    }

    // MARK: - Helpers

    /// Lets a prompt the person has not written follow the tray's folder.
    private func followFolderWithPrompt(_ target: AgentHandoffTarget) {
        guard agentEnvironment != nil else { return }
        let settings = handoffSettings(for: target)
        guard settings.promptOrigin != .edited else { return }
        let next = folderPrompt(forFolderID: handoffFolder(for: target)?.id)
        updateHandoff(target) { settings in
            settings.prompt = next.prompt
            settings.promptOrigin = next.origin
        }
    }

    /// Empty is fine — the URL is optional — but what is there has to be one.
    static func isAcceptableMCPURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
    }
}

public extension TranscriptAgentEffort {
    /// "High effort", as the tray's pill reads.
    var trayLabel: String {
        switch self {
        case .low: "Low effort"
        case .medium: "Medium effort"
        case .high: "High effort"
        case .xhigh: "Extra high effort"
        }
    }
}
