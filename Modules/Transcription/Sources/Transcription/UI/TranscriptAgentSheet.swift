import SwiftUI

/// Hands the transcript on screen to a coding agent working in a folder.
///
/// Three choices and nothing else: who does the work, where they do it, and
/// what they are being asked for. The sheet closes when the session exists;
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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    agentSection
                    folderSection
                    instructionSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .frame(maxHeight: 420)
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Send to Agent").font(.title3.weight(.semibold))
            Text("\u{201C}\(transcriptName)\u{201D} is written to a file the agent reads, and its session opens in Latch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: - Agent

    @ViewBuilder
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent").font(.headline)
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
                if let agent = viewModel.selectedAgent {
                    Text("Runs `\(agent.commandLabel)` in the folder below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            if viewModel.agentFolders.isEmpty {
                Text("Connect the folder the agent should work in. Its session opens there in Latch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Folder", selection: $viewModel.selectedAgentFolderID) {
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
                .overlay(alignment: .topLeading) {
                    if viewModel.agentInstruction.isEmpty {
                        Text(TranscriptAgentRequest.defaultInstruction)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            Text("Sent with the transcript. Leave it empty to ask for the summary above.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
