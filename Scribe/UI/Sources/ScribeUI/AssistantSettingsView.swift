import AppKit
import SwiftUI

/// The Settings tab that adds Scribe to ChatGPT, Claude, and Claude Code.
///
/// Each "Add to…" button does the part Scribe can do itself (copy the
/// connector URL and open the right page, or install the Claude Code plugin)
/// and lists the steps that only the person can do in the other app, such as
/// approving the connection. ChatGPT and Claude connect from their own cloud,
/// so both depend on the public HTTPS address entered at the top.
public struct AssistantSettingsView: View {
    @ObservedObject private var package: AssistantConnectorPackage
    @AppStorage("scribe.settings.assistantServerAddress") private var addressText = ""
    @AppStorage("scribe.settings.assistantChatGPTCallback") private var chatGPTCallback = ""
    /// What was last put on the clipboard, confirmed beside the button.
    @State private var copied: String?
    /// Why the last copy failed, shown in the section whose button was pressed.
    @State private var copyFailure: (source: CopySource, message: String)?

    private enum CopySource { case server, claudeCode }

    private static let ownerKeyURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/MCP/owner-key")

    private var address: Result<AssistantServerAddress, AssistantServerAddress.Problem> {
        AssistantServerAddress.parse(addressText)
    }

    private var validAddress: AssistantServerAddress? {
        try? address.get()
    }

    public init(package: AssistantConnectorPackage) {
        self.package = package
    }

    public var body: some View {
        Form {
            // Claude Code first: it runs on this Mac and needs nothing else.
            claudeCodeSection
            serverSection
            clientSection(.chatGPT) {
                TextField("ChatGPT callback", text: $chatGPTCallback, prompt: Text("Optional, from ChatGPT"))
            }
            clientSection(.claude) { EmptyView() }
        }
        .formStyle(.grouped)
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            TextField("Public address", text: $addressText, prompt: Text("https://scribe.example.com"))
                .textContentType(.URL)
                .autocorrectionDisabled()
            switch address {
            case .success(let server):
                LabeledContent("Connector URL") {
                    HStack {
                        Text(server.endpoint)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        copyButton("Copy", value: server.endpoint, label: "connector URL")
                    }
                }
            case .failure(let problem):
                if !addressText.isEmpty {
                    Text(AssistantServerAddress.problemDescription(problem))
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Button("Copy Server Command") { copyServerCommand() }
                    .disabled(validAddress == nil || !package.isAvailable)
                Button("Copy Owner Key") { copyOwnerKey() }
                Spacer()
                confirmation(for: ["server command", "owner key"])
            }
            Text("ChatGPT and Claude reach Scribe from the internet, never from this Mac directly. Run the server command in Terminal and keep this Mac awake, then forward an HTTPS tunnel or proxy (for example `ngrok http 8766`) to port 8766 and enter its address above. The first run creates your owner key; paste it only into Scribe’s own consent page, never into a chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            failure(in: .server)
            if !package.isAvailable {
                Text("This build does not include the connector package. Build Scribe with Scripts/build-app.sh, or follow Integrations/scribe/README.md.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Server for ChatGPT and Claude")
        }
    }

    // MARK: - ChatGPT and Claude

    private func clientSection<Extra: View>(_ client: AssistantClient, @ViewBuilder extra: () -> Extra) -> some View {
        Section(client.name) {
            HStack {
                Button("Add to \(client.name)…") { add(to: client) }
                    .buttonStyle(.borderedProminent)
                    .disabled(validAddress == nil)
                Spacer()
                confirmation(for: ["\(client.name) URL"])
            }
            if validAddress == nil {
                Text("Enter your public address above first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            extra()
            steps(for: client)
        }
    }

    private func add(to client: AssistantClient) {
        guard let server = validAddress, let page = client.setupPage else { return }
        copy(server.endpoint, label: "\(client.name) URL")
        NSWorkspace.shared.open(page)
    }

    // MARK: - Claude Code

    private var claudeCodeSection: some View {
        Section(AssistantClient.claudeCode.name) {
            HStack {
                Button("Add to Claude Code") {
                    Task { await package.installInClaudeCode() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!package.isAvailable || package.installState == .installing)
                Button("Copy Commands") { copyClaudeCodeCommands() }
                    .disabled(!package.isAvailable)
                Spacer()
                installStatus
                confirmation(for: ["Claude Code commands"])
            }
            switch package.installState {
            case .installed(let note?):
                Text(note).font(.footnote).foregroundStyle(.orange)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            default:
                EmptyView()
            }
            failure(in: .claudeCode)
            steps(for: .claudeCode)
            Text("Claude Code runs Scribe on this Mac and reads your transcripts directly, so it needs no server or public address. It requires Node.js 22 or newer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installStatus: some View {
        switch package.installState {
        case .installing:
            ProgressView().controlSize(.small)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        default:
            EmptyView()
        }
    }

    // MARK: - Shared pieces

    private func steps(for client: AssistantClient) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(client.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.footnote)
    }

    @ViewBuilder
    private func failure(in source: CopySource) -> some View {
        if let copyFailure, copyFailure.source == source {
            Text(copyFailure.message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func copyButton(_ title: String, value: String, label: String) -> some View {
        Button(title) { copy(value, label: label) }
            .controlSize(.small)
    }

    @ViewBuilder
    private func confirmation(for labels: [String]) -> some View {
        if let copied, labels.contains(copied) {
            Label("Copied \(copied)", systemImage: "doc.on.clipboard")
                .font(.callout)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func copy(_ value: String, label: String) {
        copyFailure = nil
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation { copied = label }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if copied == label { withAnimation { copied = nil } }
        }
    }

    private func copyServerCommand() {
        guard let server = validAddress else { return }
        do {
            try package.stage()
        } catch {
            copyFailure = (.server, error.localizedDescription)
            return
        }
        copy(
            AssistantConnectorCommands.serverCommand(cli: package.stagedCLI, address: server, chatGPTCallback: chatGPTCallback),
            label: "server command"
        )
    }

    private func copyClaudeCodeCommands() {
        do {
            try package.stage()
        } catch {
            copyFailure = (.claudeCode, error.localizedDescription)
            return
        }
        copy(AssistantConnectorCommands.claudeCodeInstallCommand(marketplace: package.stagedMarketplace), label: "Claude Code commands")
    }

    private func copyOwnerKey() {
        guard let key = try? String(contentsOf: Self.ownerKeyURL, encoding: .utf8) else {
            copyFailure = (.server, "No owner key yet. Run the server command once to create it.")
            return
        }
        copy(key.trimmingCharacters(in: .whitespacesAndNewlines), label: "owner key")
    }
}
