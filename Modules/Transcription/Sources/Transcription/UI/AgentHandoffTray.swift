import SwiftUI

/// The agent handoff for one meeting or transcript: the prompt, the pills
/// that say who does the work and where, and the send button.
///
/// The same tray sits under a meeting's notes in the Transcripts window and
/// in the Send to Agent sheet; it is bound to one `AgentHandoffTarget`, so
/// two meetings never share a choice. Pills open popovers rather than menus,
/// which also work in a non-activating panel. Flat surface, hairline
/// borders, pill controls, per the approved design.
struct AgentHandoffTray: View {
    enum Style {
        /// Prompt, pills and send: under the notes of a meeting being
        /// recorded or transcribed, and in the sheet.
        case full
        /// One line: where it sends and the send button. Under the notes of
        /// a finished transcript, where the transcript needs the room.
        case compact
    }

    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    var style: Style = .full
    /// The prompt folds to one line while the notes editor has focus.
    var isPromptCollapsed = false
    /// Return sends (the sheet). The window's tray leaves Return to the text.
    var sendsOnReturn = false
    /// Opens the full settings, for the compact tray.
    var onEditSettings: (() -> Void)?

    var body: some View {
        Group {
            switch style {
            case .full: fullTray
            case .compact: compactTray
            }
        }
        .task(id: target) { await viewModel.loadAgentEnvironment(for: target) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent handoff")
    }

    // MARK: - Full

    private var fullTray: some View {
        VStack(alignment: .leading, spacing: 0) {
            HandoffPromptField(viewModel: viewModel, target: target, isCollapsed: isPromptCollapsed)
                .padding(.bottom, 12)
            // One row when it fits; otherwise the send controls drop below
            // the pills, still trailing, rather than pushing past the edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    HandoffPills(viewModel: viewModel, target: target)
                    Spacer(minLength: 8)
                    sendControls
                }
                VStack(alignment: .trailing, spacing: 8) {
                    HandoffPills(viewModel: viewModel, target: target)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sendControls
                }
            }
            HandoffStatusLine(viewModel: viewModel, target: target, showsSent: false)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HandoffTrayStyle.tint)
        .overlay(alignment: .top) { Divider() }
    }

    private var sendControls: some View {
        HandoffSendControls(viewModel: viewModel, target: target, sendsOnReturn: sendsOnReturn, showsSentText: false)
    }

    // MARK: - Compact

    private var compactTray: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HandoffCompactSummary(viewModel: viewModel, target: target, onEditSettings: onEditSettings)
                Spacer(minLength: 8)
                HandoffSendControls(viewModel: viewModel, target: target, sendsOnReturn: false, showsSentText: false)
            }
            HandoffStatusLine(viewModel: viewModel, target: target, showsSent: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HandoffTrayStyle.tint, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(HandoffTrayStyle.hairline) }
    }
}

enum HandoffTrayStyle {
    static let tint = Color.primary.opacity(0.035)
    static let hairline = Color.primary.opacity(0.10)
    static let pillBorder = Color.primary.opacity(0.22)
    static let sentGreen = Color(nsColor: .systemGreen)
}

// MARK: - Prompt

/// "Prompt" with Recent beside it, then the prompt itself. While the notes
/// have focus it folds to one line so the notes keep the room.
private struct HandoffPromptField: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    let isCollapsed: Bool
    @State private var isShowingRecent = false

    var body: some View {
        let prompt = viewModel.handoffSettings(for: target).prompt
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                if isCollapsed {
                    Text(prompt)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Prompt: \(prompt)")
                } else {
                    Spacer(minLength: 0)
                }
                recentButton
            }
            if !isCollapsed {
                TextEditor(text: Binding(
                    get: { viewModel.handoffSettings(for: target).prompt },
                    set: { viewModel.setHandoffPrompt($0, for: target) }
                ))
                .font(.body)
                .scrollContentBackground(.hidden)
                // Two to three lines; a longer prompt scrolls. A fixed height
                // keeps the notes above from being squeezed as it grows.
                .frame(height: 54)
                .accessibilityLabel("Prompt")
                .accessibilityHint("What the agent is asked to do with the transcript and notes")
            }
        }
    }

    private var recentButton: some View {
        Button {
            isShowingRecent = true
        } label: {
            Label("Recent", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(recentHelp)
        .popover(isPresented: $isShowingRecent, arrowEdge: .bottom) {
            HandoffRecentPrompts(viewModel: viewModel, target: target) { isShowingRecent = false }
        }
    }

    private var recentHelp: String {
        if let folder = viewModel.handoffFolder(for: target) {
            return "The last prompts sent to agents working in \(folder.displayName)"
        }
        return "The last prompts sent without a folder"
    }
}

/// The folder's recent prompts. Choosing one replaces the prompt; the
/// folder's own can be brought back after the prompt was edited.
private struct HandoffRecentPrompts: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    let close: () -> Void

    var body: some View {
        let history = viewModel.handoffPromptHistory(for: target)
        let current = viewModel.handoffSettings(for: target)
        VStack(alignment: .leading, spacing: 0) {
            if history.isEmpty {
                Text("No prompts have been sent \(folderPhrase) yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(Array(history.enumerated()), id: \.element) { index, prompt in
                    if index > 0 { Divider() }
                    HandoffChoiceRow(title: prompt, isChosen: prompt == current.prompt, lineLimit: 2) {
                        viewModel.chooseRecentPrompt(prompt, for: target)
                        close()
                    }
                }
            }
            if current.promptOrigin == .edited {
                Divider()
                HandoffChoiceRow(title: "Use the folder\u{2019}s prompt", isChosen: false, systemImage: "arrow.uturn.backward") {
                    viewModel.resetHandoffPrompt(for: target)
                    close()
                }
            }
        }
        .frame(width: 340)
        .padding(.vertical, 4)
    }

    private var folderPhrase: String {
        viewModel.handoffFolder(for: target).map { "into \($0.displayName)" } ?? "without a folder"
    }
}

// MARK: - Pills

private struct HandoffPills: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget

    var body: some View {
        // One line where there is room (the Transcripts window); wrapped onto
        // more lines in the narrow floating notes panel.
        HandoffFlowLayout(spacing: 6, lineSpacing: 6) {
            HandoffAgentPill(viewModel: viewModel, target: target)
            HandoffModelPill(viewModel: viewModel, target: target)
            if viewModel.handoffAgent(for: target)?.supportsEffort == true {
                HandoffEffortPill(viewModel: viewModel, target: target)
            }
            HandoffFolderPill(viewModel: viewModel, target: target)
            HandoffOverflowPill(viewModel: viewModel, target: target)
        }
    }
}

/// Lays its subviews out left to right at their ideal sizes, starting a new
/// line when the next one would not fit. Its ideal size is everything on
/// one line. A subview wider than the whole width gets that width, so a long
/// pill title truncates rather than overflowing.
struct HandoffFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    struct Placement: Equatable {
        var origin: CGPoint
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let placements = Self.arrange(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width, spacing: spacing, lineSpacing: lineSpacing)
        return Self.bounds(of: placements)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let placements = Self.arrange(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width, spacing: spacing, lineSpacing: lineSpacing)
        for (subview, placement) in zip(subviews, placements) {
            subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    /// Where each subview goes, given its ideal size and the width available
    /// (nil or infinite: one line).
    static func arrange(sizes: [CGSize], width: CGFloat?, spacing: CGFloat, lineSpacing: CGFloat) -> [Placement] {
        let limit = width.flatMap { $0.isFinite ? max($0, 0) : nil } ?? .infinity
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var lineIsEmpty = true
        for ideal in sizes {
            let size = CGSize(width: min(ideal.width, limit), height: ideal.height)
            if !lineIsEmpty, x + spacing + size.width > limit {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
                lineIsEmpty = true
            }
            let originX = lineIsEmpty ? 0 : x + spacing
            placements.append(Placement(origin: CGPoint(x: originX, y: y), size: size))
            x = originX + size.width
            lineHeight = max(lineHeight, size.height)
            lineIsEmpty = false
        }
        return placements
    }

    static func bounds(of placements: [Placement]) -> CGSize {
        CGSize(
            width: placements.map { $0.origin.x + $0.size.width }.max() ?? 0,
            height: placements.map { $0.origin.y + $0.size.height }.max() ?? 0
        )
    }
}

private struct HandoffAgentPill: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    @State private var isOpen = false

    var body: some View {
        let agent = viewModel.handoffAgent(for: target)
        let named = viewModel.handoffSettings(for: target).agentID
        let isMissing = viewModel.agentEnvironment != nil && agent == nil && named != nil
        HandoffPillButton(
            title: agent?.displayName ?? (isMissing ? "\(named ?? "") missing" : "Agent"),
            isWarning: isMissing,
            accessibilityLabel: "Agent: \(agent?.displayName ?? "none chosen")"
        ) { isOpen = true }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.agents.isEmpty {
                    Text(viewModel.agentEnvironment?.unavailableReason ?? "No coding agent was found on this Mac. Install Claude Code, Codex, Gemini CLI, or Cursor Agent.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                } else {
                    ForEach(viewModel.agents) { candidate in
                        HandoffChoiceRow(title: candidate.displayName, detail: candidate.commandLabel, isChosen: candidate.id == agent?.id) {
                            viewModel.selectHandoffAgent(candidate.id, for: target)
                            isOpen = false
                        }
                    }
                }
            }
            .frame(width: 240)
            .padding(.vertical, 4)
        }
    }
}

/// Free text, because model names change faster than Scribe ships, with the
/// names typed for this agent before one click away.
private struct HandoffModelPill: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    @State private var isOpen = false

    var body: some View {
        let model = viewModel.handoffSettings(for: target).model.trimmingCharacters(in: .whitespacesAndNewlines)
        HandoffPillButton(
            title: model.isEmpty ? "Default model" : model,
            accessibilityLabel: "Model: \(model.isEmpty ? "the agent\u{2019}s default" : model)"
        ) { isOpen = true }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Model", text: Binding(
                    get: { viewModel.handoffSettings(for: target).model },
                    set: { viewModel.setHandoffModel($0, for: target) }
                ), prompt: Text("Model (agent default)"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { isOpen = false }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                let history = viewModel.handoffModelHistory(for: target)
                if !history.isEmpty {
                    Divider()
                    ForEach(history, id: \.self) { name in
                        HandoffChoiceRow(title: name, isChosen: name == model) {
                            viewModel.setHandoffModel(name, for: target)
                            isOpen = false
                        }
                    }
                } else {
                    Text("Leave empty for the agent\u{2019}s own default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: 260)
            .padding(.bottom, 6)
        }
    }
}

/// Shown only for agents whose command line takes an effort.
private struct HandoffEffortPill: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    @State private var isOpen = false

    var body: some View {
        let effort = viewModel.handoffEffort(for: target)
        HandoffPillButton(
            title: effort?.trayLabel ?? "Default effort",
            accessibilityLabel: "Effort: \(effort?.trayLabel ?? "the agent\u{2019}s default")"
        ) { isOpen = true }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HandoffChoiceRow(title: "Default effort", isChosen: effort == nil) {
                    viewModel.setHandoffEffort(nil, for: target)
                    isOpen = false
                }
                Divider()
                ForEach(TranscriptAgentEffort.allCases) { level in
                    HandoffChoiceRow(title: level.trayLabel, isChosen: level == effort) {
                        viewModel.setHandoffEffort(level, for: target)
                        isOpen = false
                    }
                }
            }
            .frame(width: 200)
            .padding(.vertical, 4)
        }
    }
}

/// The folder the session opens in: a connected folder, or "No folder".
private struct HandoffFolderPill: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    @State private var isOpen = false
    @State private var folderAwaitingRemoval: TranscriptAgentFolder?

    var body: some View {
        let folder = viewModel.handoffFolder(for: target)
        let isMissing = viewModel.handoffFolderIsMissing(for: target)
        let title = isMissing ? "Folder missing" : (folder?.displayName ?? (viewModel.agentEnvironment == nil ? "Folder" : "No folder"))
        HandoffPillButton(
            title: title,
            systemImage: "folder",
            showsChevron: false,
            isWarning: isMissing || folder?.isReachable == false,
            accessibilityLabel: "Folder: \(title)"
        ) { isOpen = true }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { folderChoices(current: folder) }
        .confirmationDialog(
            "Disconnect \u{201C}\(folderAwaitingRemoval?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { folderAwaitingRemoval != nil },
                set: { if !$0 { folderAwaitingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: folderAwaitingRemoval
        ) { candidate in
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnectAgentFolder(id: candidate.id, for: target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Scribe forgets the folder. Nothing inside it is changed or removed.")
        }
    }

    private func folderChoices(current: TranscriptAgentFolder?) -> some View {
        let selection = viewModel.handoffSettings(for: target).folder
        return VStack(alignment: .leading, spacing: 0) {
            HandoffChoiceRow(title: "No folder", detail: "The agent answers in its session", isChosen: selection == .none) {
                viewModel.selectHandoffFolder(.none, for: target)
                isOpen = false
            }
            if !viewModel.agentFolders.isEmpty { Divider() }
            ForEach(viewModel.agentFolders) { candidate in
                HandoffChoiceRow(
                    title: candidate.isReachable ? candidate.displayName : "\(candidate.displayName) (missing)",
                    detail: candidate.pathDescription,
                    isChosen: selection != .none && candidate.id == current?.id
                ) {
                    viewModel.selectHandoffFolder(.folder(candidate.id), for: target)
                    isOpen = false
                }
            }
            Divider()
            HandoffChoiceRow(title: "Connect Folder\u{2026}", isChosen: false, systemImage: "plus") {
                isOpen = false
                Task { await viewModel.connectAgentFolder(for: target) }
            }
            if let current, selection != .none {
                HandoffChoiceRow(title: "Disconnect \(current.displayName)\u{2026}", isChosen: false, systemImage: "minus.circle") {
                    isOpen = false
                    folderAwaitingRemoval = current
                }
            }
        }
        .frame(width: 300)
        .padding(.vertical, 4)
    }
}

/// Settings used rarely: the MCP server the agent is told about.
private struct HandoffOverflowPill: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    @State private var isOpen = false

    var body: some View {
        let mcpURL = viewModel.handoffSettings(for: target).mcpURL
        let isInvalid = !TranscriptViewModel.isAcceptableMCPURL(mcpURL)
        HandoffPillButton(
            title: "",
            systemImage: "ellipsis",
            showsChevron: false,
            isWarning: isInvalid,
            accessibilityLabel: "More handoff settings"
        ) { isOpen = true }
        .help("More handoff settings")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MCP server").font(.headline)
                TextField("MCP URL", text: Binding(
                    get: { viewModel.handoffSettings(for: target).mcpURL },
                    set: { viewModel.setHandoffMCPURL($0, for: target) }
                ), prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { isOpen = false }
                Text(isInvalid ? "The MCP URL should start with http:// or https://." : "Optional. The agent is told related information can be found there.")
                    .font(.caption)
                    .foregroundStyle(isInvalid ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 300)
            .padding(12)
        }
    }
}

// MARK: - Send

/// The trailing controls, per the tray states: Send to agent; Send after
/// processing; Will send when ready with Cancel send; Ready to send — confirm
/// with Send and Cancel; Sending…; Sent with Open in Latch and Send again;
/// Couldn't send with Try again.
private struct HandoffSendControls: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    let sendsOnReturn: Bool
    var showsSentText = true

    var body: some View {
        HStack(spacing: 6) {
            switch viewModel.handoffTrayState(for: target) {
            case .canQueue:
                HandoffPrimaryButton(
                    title: "Send after processing",
                    isEnabled: viewModel.handoffSettingsProblem(for: target) == nil,
                    sendsOnReturn: sendsOnReturn
                ) {
                    Task { await viewModel.queueSend(target) }
                }
                .help("Send the transcript, prompt and notes to the agent when transcription finishes")
            case .waiting:
                Label("Will send when ready", systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HandoffSecondaryButton(title: "Cancel send") {
                    Task { await viewModel.cancelQueuedSend(target) }
                }
            case .held:
                HandoffSecondaryButton(title: "Cancel") {
                    Task { await viewModel.cancelQueuedSend(target) }
                }
                HandoffPrimaryButton(title: "Send", isEnabled: true, sendsOnReturn: sendsOnReturn) {
                    Task { await viewModel.confirmHeldSend(target) }
                }
            case .unconfirmed:
                HandoffSecondaryButton(title: "Dismiss") {
                    Task { await viewModel.dismissUnconfirmedSend(target) }
                }
                .help("Stop asking. Check Latch first: the agent may already be running.")
                HandoffPrimaryButton(title: "Try again", isEnabled: true, sendsOnReturn: sendsOnReturn) {
                    Task { await viewModel.retryUnconfirmedSend(target) }
                }
                .help("Ask Latch again. If the agent already started, Latch returns that session instead of starting another.")
            case .manual(.sending?):
                ProgressView().controlSize(.small)
                HandoffPrimaryButton(title: "Sending\u{2026}", isEnabled: false) {}
            case .manual(.sent(let outcome)?):
                if showsSentText {
                    Label(outcome.sentDescription, systemImage: "checkmark")
                        .font(.system(size: 12))
                        .foregroundStyle(HandoffTrayStyle.sentGreen)
                        .lineLimit(1)
                }
                if outcome.sessionID != nil {
                    HandoffSecondaryButton(title: "Open in Latch") {
                        Task { await viewModel.openHandoffSession(for: target) }
                    }
                }
                HandoffSecondaryButton(title: "Send again", isEnabled: viewModel.canSubmitHandoff(target)) {
                    Task { await viewModel.sendToAgent(target) }
                }
            case .manual(.failed?):
                HandoffPrimaryButton(title: "Try again", isEnabled: viewModel.canSubmitHandoff(target), sendsOnReturn: sendsOnReturn) {
                    Task { await viewModel.sendToAgent(target) }
                }
            case .manual(nil):
                HandoffPrimaryButton(title: "Send to agent", isEnabled: viewModel.canSubmitHandoff(target), sendsOnReturn: sendsOnReturn) {
                    Task { await viewModel.sendToAgent(target) }
                }
            }
        }
        .fixedSize()
    }
}

/// One caption under the controls: why the tray cannot send, where a queued
/// send will go, why it is waiting for the person, why the last send failed
/// (notes are kept), or where it went.
private struct HandoffStatusLine: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    var showsSent = true

    var body: some View {
        Group {
            switch viewModel.handoffTrayState(for: target) {
            case .manual(.failed(let message)?):
                line(failureText(message), color: .red, systemImage: "exclamationmark.triangle.fill")
            case .manual(.sent(let outcome)?) where !showsSent:
                line(outcome.sentDescription, color: HandoffTrayStyle.sentGreen, systemImage: "checkmark")
            case .manual(.sending?), .manual(.sent?):
                EmptyView()
            case .waiting:
                // Decision 6: the destination as it stands now, which is
                // what will be used when the send fires.
                line("Sends to \(viewModel.handoffDestinationSummary(for: target)) when the transcript is ready.", color: .secondary, systemImage: "paperplane")
                if let problem = viewModel.handoffSettingsProblem(for: target), viewModel.agentEnvironment != nil {
                    line(problem, color: .orange, systemImage: "exclamationmark.triangle")
                }
            case .held(let reason):
                line("Ready to send \u{2014} confirm. \(reason.explanation)", color: .orange, systemImage: "hand.raised")
            case .unconfirmed(let message):
                line("\(message) Scribe couldn\u{2019}t confirm whether the agent started. Try again asks Latch without starting a second one.", color: .red, systemImage: "questionmark.circle")
            case .canQueue, .manual(nil):
                if let problem = viewModel.handoffSettingsProblem(for: target) ?? viewModel.handoffProblem(for: target),
                   viewModel.agentEnvironment != nil {
                    line(problem, color: .secondary, systemImage: nil)
                }
            }
        }
    }

    private func failureText(_ message: String) -> String {
        viewModel.handoffNotes(for: target)?.notes.isEmpty == false ? "\(message) Your notes are kept." : message
    }

    @ViewBuilder
    private func line(_ text: String, color: Color, systemImage: String?) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(color)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
}

/// "Claude Code · opus · tough-leaf", which opens the full settings.
private struct HandoffCompactSummary: View {
    @Bindable var viewModel: TranscriptViewModel
    let target: AgentHandoffTarget
    let onEditSettings: (() -> Void)?

    var body: some View {
        let summary = viewModel.handoffDestinationSummary(for: target)
        if let onEditSettings {
            Button(action: onEditSettings) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane").font(.system(size: 11))
                    Text(summary).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the agent, model, folder or prompt")
            .accessibilityLabel("Sends to \(summary). Change handoff settings")
        } else {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Controls

/// Draws only the label, dimmed while pressed: no AppKit bezel under the
/// pill outlines.
private struct HandoffTrayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct HandoffPillButton: View {
    let title: String
    var systemImage: String?
    var showsChevron = true
    var isWarning = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                if !title.isEmpty { Text(title).lineLimit(1) }
                if showsChevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }
            .font(.system(size: 12))
            .frame(minHeight: 15)
            .foregroundStyle(isWarning ? Color.red : Color.primary.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay { Capsule().strokeBorder(isWarning ? Color.red.opacity(0.6) : HandoffTrayStyle.pillBorder) }
            .contentShape(Capsule())
        }
        .buttonStyle(HandoffTrayButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct HandoffPrimaryButton: View {
    let title: String
    var isEnabled = true
    var sendsOnReturn = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(isEnabled ? 0.9 : 0.3), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(HandoffTrayButtonStyle())
        .disabled(!isEnabled)
        if sendsOnReturn {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }
}

private struct HandoffSecondaryButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.78 : 0.35))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay { Capsule().strokeBorder(HandoffTrayStyle.pillBorder) }
                .contentShape(Capsule())
        }
        .buttonStyle(HandoffTrayButtonStyle())
        .disabled(!isEnabled)
    }
}

/// One choice in a pill's popover: a check beside the chosen one.
private struct HandoffChoiceRow: View {
    let title: String
    var detail: String?
    let isChosen: Bool
    var systemImage: String?
    var lineLimit = 1
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: systemImage ?? "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .opacity(systemImage != nil || isChosen ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .lineLimit(lineLimit)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
