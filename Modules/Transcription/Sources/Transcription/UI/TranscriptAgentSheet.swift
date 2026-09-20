import SwiftUI

/// Hands the transcript on screen to a coding agent working in a folder.
///
/// Who does the work and how hard they think, where they do it if anywhere,
/// what else they can consult, and what they are being asked for. The sheet closes when the session exists;
/// a refusal keeps it open with the reason, because every field is still worth
/// keeping when the send did not happen.
struct TranscriptAgentSheet: View {
    @Bindable var viewModel: TranscriptViewModel
    let transcriptName: String
    let dismiss: () -> Void

    @State private var folderAwaitingRemoval: TranscriptAgentFolder?
    @FocusState private var isInstructionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agentSection
                    folderSection
                    mcpSection
                    instructionSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 480)
            Divider()
            footer
        }
        .frame(width: 520)
        .task { await viewModel.loadAgentEnvironment() }
        .onAppear { isInstructionFocused = true }
        .confirmationDialog(
            "Disconnect \u{201C}\(folderAwaitingRemoval?.displayName ?? "")\u{201D}?",
            isPresented: Binding(
                get: { folderAwaitingRemoval != nil },
                set: { if !$0 { folderAwaitingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: folderAwaitingRemoval
        ) { folder in
            Button("Disconnect", role: .destructive) {
                Task { await viewModel.disconnectAgentFolder(id: folder.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Scribe forgets the folder. Nothing inside it is changed or removed.")
        }
    }

    private var header: some View {
        Text("Send to Agent")
            .font(.title3.weight(.semibold))
            .help("\u{201C}\(transcriptName)\u{201D}")
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)
    }

    // MARK: - Agent

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.agents.isEmpty {
                unavailableNote(
                    viewModel.agentEnvironment?.unavailableReason
                        ?? "No coding agent was found on this Mac. Install Claude Code, Codex, Gemini CLI, or Cursor Agent and open this sheet again."
                )
            } else {
                Picker("Agent", selection: $viewModel.selectedAgentID) {
                    ForEach(viewModel.agents) { agent in
                        Text(agent.displayName).tag(TranscriptAgent.ID?.some(agent.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                HStack(spacing: 8) {
                    modelField
                    if viewModel.selectedAgent?.supportsEffort == true {
                        Picker("Effort", selection: $viewModel.agentEffort) {
                            Text("Default effort").tag(TranscriptAgentEffort?.none)
                            Divider()
                            ForEach(TranscriptAgentEffort.allCases) { effort in
                                Text(effort.rawValue).tag(TranscriptAgentEffort?.some(effort))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// A combo box in two parts: free text, because model names change faster
    /// than Scribe ships, and beside it the names typed for this agent before.
    private var modelField: some View {
        HStack(spacing: 4) {
            TextField("Model", text: $viewModel.agentModel, prompt: Text("Model (agent default)"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Menu {
                ForEach(viewModel.agentModelHistory, id: \.self) { model in
                    Button(model) { viewModel.agentModel = model }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(viewModel.agentModelHistory.isEmpty)
            .help("Recently used models")
        }
    }

    // MARK: - Folder

    @ViewBuilder
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Folder").font(.headline)
                Spacer(minLength: 0)
                Button("Connect Folder…") {
                    Task { await viewModel.connectAgentFolder() }
                }
                .controlSize(.small)
            }
            if !viewModel.agentFolders.isEmpty {
                Picker("Folder", selection: Binding(
                    get: { viewModel.selectedAgentFolderID },
                    set: { viewModel.selectAgentFolder(id: $0) }
                )) {
                    Text("No Folder").tag(TranscriptAgentFolder.ID?.none)
                    Divider()
                    ForEach(viewModel.agentFolders) { folder in
                        Text(folder.isReachable ? folder.displayName : "\(folder.displayName) (missing)")
                            .tag(TranscriptAgentFolder.ID?.some(folder.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if let folder = viewModel.selectedAgentFolder {
                    HStack(spacing: 8) {
                        Text(folder.pathDescription)
                            .font(.caption)
                            .foregroundStyle(folder.isReachable ? Color.secondary : Color.red)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                        Button("Disconnect") { folderAwaitingRemoval = folder }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - MCP

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MCP").font(.headline)
            TextField("MCP URL", text: $viewModel.agentMCPURL, prompt: Text("https://"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }

    // MARK: - Instruction

    @ViewBuilder
    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instruction").font(.headline)
            TextEditor(text: $viewModel.agentInstruction)
                .focused($isInstructionFocused)
                .font(.body)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.isSendingToAgent {
                ProgressView().controlSize(.small)
                Text("Starting the session…").font(.callout).foregroundStyle(.secondary)
            } else if let message = viewModel.agentMessage, message.isFailure {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let problem = viewModel.agentHandoffProblem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Send to Agent") {
                Task { if await viewModel.sendToAgent() { dismiss() } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canSubmitAgentHandoff)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func unavailableNote(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
