import AppKit
import SwiftUI

/// The Settings tab that adds Scribe to ChatGPT, Claude, and Claude Code.
///
/// Each "Add to…" button does the part Scribe can do itself (copy the
/// connector URL and open the right page, or install the Claude Code plugin)
/// and lists the steps that only the person can do in the other app, such as
/// approving the connection. ChatGPT and Claude connect from their own cloud,
/// so both depend on a public HTTPS address: a Scribe relay this Mac links to
/// (no tunnel), or the person's own tunnel to a local server.
public struct AssistantSettingsView: View {
    @ObservedObject private var package: AssistantConnectorPackage
    @ObservedObject private var relayAgent: AssistantRelayAgent
    @AppStorage("scribe.settings.assistantConnectionMode") private var mode = AssistantConnectionMode.relay
    @AppStorage(AssistantRelayAgent.relayAddressKey) private var relayText = ""
    @AppStorage("scribe.settings.assistantServerAddress") private var addressText = ""
    @AppStorage("scribe.settings.assistantChatGPTCallback") private var chatGPTCallback = ""
    /// What was last put on the clipboard, confirmed beside the button.
    @State private var copied: String?
    /// Why the last copy failed, shown in the section whose button was pressed.
    @State private var copyFailure: (source: CopySource, message: String)?

    /// The last one-time link code fetched from the relay, shown until used.
    @State private var linkCode: String?
    @State private var linkCodeExpiry: Date?
    @State private var relayStatus: String?
    @State private var relayBusy = false
    @State private var confirmingUnlink = false

    private enum CopySource { case server, claudeCode }

    private static let ownerKeyURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/MCP/owner-key")

    private var address: Result<AssistantServerAddress, AssistantServerAddress.Problem> {
        AssistantServerAddress.parse(mode == .relay ? relayText : addressText)
    }

    /// The connector URL clients are given, for whichever mode is chosen.
    private var validAddress: AssistantServerAddress? {
        try? address.get()
    }

    public init(package: AssistantConnectorPackage, relayAgent: AssistantRelayAgent = .shared) {
        self.package = package
        self.relayAgent = relayAgent
    }

    public var body: some View {
        Form {
            // Claude Code first: it runs on this Mac and needs nothing else.
            claudeCodeSection
            Section {
                Picker("Connect through", selection: $mode) {
                    ForEach(AssistantConnectionMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("ChatGPT and Claude")
            } footer: {
                Text(mode == .relay
                    ? "This Mac links to a Scribe relay, which gives your library one stable HTTPS address. Scribe only connects out, so no tunnel or open port is needed. Assistants read only this library, only after you approve them with a link code, and you can disconnect them here."
                    : "Run Scribe’s server on this Mac behind your own HTTPS tunnel or proxy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if mode == .relay { relaySection } else { serverSection }
            clientSection(.chatGPT) {
                if mode == .selfHosted {
                    TextField("ChatGPT callback", text: $chatGPTCallback, prompt: Text("Optional, from ChatGPT"))
                }
            }
            clientSection(.claude) { EmptyView() }
        }
        .formStyle(.grouped)
        .onAppear {
            // A build packaged for a relay offers it, the same one its ChatGPT plugin
            // names; otherwise Scribe's own relay.
            if relayText.isEmpty { relayText = package.packagedRelay?.origin ?? AssistantRelayAgent.defaultRelayOrigin }
        }
    }

    // MARK: - Relay

    /// Status first, then the one thing to do in each state: connect, or get a
    /// link code once connected. The relay address and the Terminal command are
    /// for people running their own relay, so they sit under Relay Settings.
    private var relaySection: some View {
        Section {
            relayStatusRow
            if relayAgent.state == .connected { linkCodeCard }
            if AssistantRelayAgent.isLinked {
                HStack {
                    Button("Disconnect All Assistants") { runRelay(["revoke", "--all"]) { _ in relayStatus = "Every assistant was disconnected. Each one needs a new link code to reconnect." } }
                    Button("Unlink This Mac…", role: .destructive) { confirmingUnlink = true }
                    Spacer()
                    if relayBusy { ProgressView().controlSize(.small) }
                }
                .disabled(relayBusy || !package.isAvailable)
                .confirmationDialog("Unlink this Mac from the relay?", isPresented: $confirmingUnlink) {
                    Button("Unlink", role: .destructive) {
                        relayAgent.stop()
                        runRelay(["unlink"]) { _ in
                            linkCode = nil
                            relayStatus = "This Mac was unlinked. The relay forgot its connections."
                        }
                    }
                } message: {
                    Text("Every assistant loses access, and the relay forgets this library. Connecting again links this Mac anew.")
                }
            }
            if let relayStatus {
                Text(relayStatus).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            failure(in: .server)
            unavailableNote
            DisclosureGroup("Relay Settings") {
                TextField("Relay address", text: $relayText, prompt: Text(AssistantRelayAgent.defaultRelayOrigin))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .disabled(AssistantRelayAgent.isLinked)
                    .help(AssistantRelayAgent.isLinked ? "Unlink this Mac to change relays." : "")
                addressDetail
                HStack {
                    Text("To serve from Terminal instead of Scribe, copy the connect command.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    confirmation(for: ["connect command"])
                    Button("Copy Connect Command") { copyRelayCommand() }
                        .disabled(validAddress == nil || !package.isAvailable)
                }
            }
        } header: {
            Text("Scribe Relay")
        } footer: {
            Text("Transcripts pass through the relay only while an assistant is reading them. The relay never stores them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var isFailed: Bool {
        if case .failed = relayAgent.state { true } else { false }
    }

    private var relayHost: String {
        validAddress.flatMap { URL(string: $0.origin)?.host() } ?? "the relay"
    }

    /// What the connection is doing, in words, with the button that changes it.
    private var relayStatusRow: some View {
        HStack(alignment: .center, spacing: 12) {
            relayStatusIcon
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(relayStatusTitle).font(.headline)
                Text(relayStatusDetail)
                    .font(.callout)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if relayAgent.state == .stopped || isFailed {
                Button(isFailed ? "Try Again" : "Connect This Mac") {
                    relayStatus = nil
                    if let relay = validAddress { relayAgent.start(package: package, relay: relay) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(validAddress == nil || !package.isAvailable)
            } else {
                Button("Disconnect") { relayAgent.stop() }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var relayStatusIcon: some View {
        switch relayAgent.state {
        case .stopped:
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .retrying:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var relayStatusTitle: String {
        switch relayAgent.state {
        case .stopped: AssistantRelayAgent.isLinked ? "Not connected" : "Not connected yet"
        case .connecting: "Connecting…"
        case .connected: "Connected to \(relayHost)"
        case .retrying: "Reconnecting…"
        case .failed: "Couldn’t connect"
        }
    }

    private var relayStatusDetail: String {
        switch relayAgent.state {
        case .stopped:
            AssistantRelayAgent.isLinked
                ? "Assistants can’t read this Mac’s transcripts until you connect again."
                : "Connect this Mac so ChatGPT and Claude can read its transcripts after you approve them."
        case .connecting:
            "Linking this Mac to \(relayHost)."
        case .connected:
            "Scribe stays connected while it’s open. Keep this Mac awake while assistants use it."
        case .retrying(let reason):
            reason
        case .failed(let reason):
            reason
        }
    }

    /// The one-time code a person types on Scribe's consent page to approve an assistant.
    private var linkCodeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link code").font(.headline)
                    Text("Approves one assistant for this library.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if relayBusy { ProgressView().controlSize(.small) }
                Button(linkCode == nil ? "Get Link Code" : "New Code") {
                    runRelay(["code"]) { code in
                        linkCode = code
                        linkCodeExpiry = .now.addingTimeInterval(600)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(relayBusy || !package.isAvailable)
            }
            TimelineView(.everyMinute) { context in
                if let linkCode, let linkCodeExpiry, linkCodeExpiry > context.date {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text(linkCode)
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .tracking(3)
                                .textSelection(.enabled)
                                .accessibilityLabel("Link code \(linkCode.map(String.init).joined(separator: " "))")
                            Spacer()
                            confirmation(for: ["link code"])
                            Button("Copy") { copy(linkCode, label: "link code") }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("Type it on Scribe’s consent page when ChatGPT or Claude asks, never in a chat. It works once and expires at \(linkCodeExpiry.formatted(date: .omitted, time: .shortened)).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(linkCode == nil
                        ? "When an assistant opens Scribe’s consent page, get a code here and type it there."
                        : "That code expired. Get a new one when an assistant asks.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func runRelay(_ arguments: [String], then done: @escaping (String) -> Void) {
        relayBusy = true
        relayStatus = nil
        copyFailure = nil
        Task {
            defer { relayBusy = false }
            do {
                done(try await package.runRelayCommand(arguments))
            } catch {
                let message = error.localizedDescription
                copyFailure = (.server, message.contains("not linked")
                    ? "Connect this Mac first, then get a link code."
                    : message.replacingOccurrences(of: "Scribe MCP: ", with: ""))
            }
        }
    }

    private func copyRelayCommand() {
        guard let relay = validAddress else { return }
        do {
            try package.stage()
        } catch {
            copyFailure = (.server, error.localizedDescription)
            return
        }
        copy(AssistantConnectorCommands.relayConnectCommand(cli: package.stagedCLI, relay: relay), label: "connect command")
    }

    @ViewBuilder
    private var addressDetail: some View {
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
            if !(mode == .relay ? relayText : addressText).isEmpty {
                Text(AssistantServerAddress.problemDescription(problem))
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var unavailableNote: some View {
        if !package.isAvailable {
            Text("This build does not include the connector package. Build Scribe with Scripts/build-app.sh, or follow Integrations/scribe/README.md.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section {
            TextField("Public address", text: $addressText, prompt: Text("https://scribe.example.com"))
                .textContentType(.URL)
                .autocorrectionDisabled()
            addressDetail
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
            unavailableNote
        } header: {
            Text("Your own server")
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
                Text(mode == .relay ? "Enter the relay address above first." : "Enter your public address above first.")
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
            ForEach(Array(client.steps(mode: mode).enumerated()), id: \.offset) { index, step in
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
