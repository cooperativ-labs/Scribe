import AppKit
import SwiftUI

/// The Settings tab that adds Scribe to assistants.
///
/// "On this Mac" installs the local plugin into ChatGPT desktop and Codex,
/// Claude Code and Claude Desktop, and Cursor; each runs the transcript server
/// inside Scribe.app and needs nothing else. "From anywhere" links this Mac to
/// a Scribe relay, which gives ChatGPT and Claude on the web, which connect
/// from their own cloud, one public HTTPS address without a tunnel. Each "Add
/// to…" button does the part Scribe can do itself (copy the connector URL and
/// open the right page) and lists the steps only the person can do there.
public struct AssistantSettingsView: View {
    @ObservedObject private var package: AssistantConnectorPackage
    @ObservedObject private var relayAgent: AssistantRelayAgent
    @AppStorage(AssistantRelayAgent.relayAddressKey) private var relayText = ""
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
    @State private var confirmingRemoval: AssistantHarness?

    private enum CopySource { case server }

    private var address: Result<AssistantServerAddress, AssistantServerAddress.Problem> {
        AssistantServerAddress.parse(relayText)
    }

    /// The connector URL web clients are given.
    private var validAddress: AssistantServerAddress? {
        try? address.get()
    }

    public init(package: AssistantConnectorPackage, relayAgent: AssistantRelayAgent = .shared) {
        self.package = package
        self.relayAgent = relayAgent
    }

    public var body: some View {
        Form {
            localSection
            relaySection
            clientSection(.chatGPT)
            clientSection(.claude)
        }
        .formStyle(.grouped)
        .onAppear {
            // A build packaged for a relay offers it, the same one its ChatGPT plugin
            // names; otherwise Scribe's own relay.
            if relayText.isEmpty { relayText = package.packagedRelay?.origin ?? AssistantRelayAgent.defaultRelayOrigin }
            package.refreshPlugins()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // An assistant may have been installed or its plugin removed meanwhile.
            package.refreshPlugins()
        }
    }

    // MARK: - On this Mac

    private var localSection: some View {
        Section {
            ForEach(AssistantHarness.allCases) { pluginRow($0) }
            unavailableNote
        } header: {
            Text("On this Mac")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Restart the assistant after installing, updating, or removing its plugin.")
                Text("The plugin runs the read-only transcript server inside Scribe.app, so updating Scribe needs no plugin update. When an assistant reads a transcript, its text is sent to that assistant’s cloud service, like anything else in the chat.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func pluginRow(_ harness: AssistantHarness) -> some View {
        let state = package.plugin(harness)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.name).font(.headline)
                    if let covers = harness.covers {
                        Text(covers).font(.callout).foregroundStyle(.secondary)
                    }
                    Label(
                        state.isDetected ? "Detected on this Mac" : "Not detected on this Mac",
                        systemImage: state.isDetected ? "checkmark.circle" : "questionmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if state.isWorking { ProgressView().controlSize(.small) }
                if state.status != .notInstalled {
                    Button("Remove", role: .destructive) { confirmingRemoval = harness }
                        .disabled(state.isWorking)
                }
                pluginButton(harness, state: state)
            }
            if let message = state.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(state.failed ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "Remove the Scribe plugin from \(harness.name)?",
            isPresented: Binding(get: { confirmingRemoval == harness }, set: { if !$0 { confirmingRemoval = nil } })
        ) {
            Button("Remove", role: .destructive) { Task { await package.remove(harness) } }
        } message: {
            Text("Scribe deletes the plugin files it installed and its entries in \(harness.covers ?? harness.name). Files you changed are kept.")
        }
    }

    @ViewBuilder
    private func pluginButton(_ harness: AssistantHarness, state: AssistantConnectorPackage.PluginState) -> some View {
        switch state.status {
        case .notInstalled:
            Button("Install \(harness.name) Plugin") { Task { await package.install(harness) } }
                .buttonStyle(.borderedProminent)
                .disabled(!package.isAvailable || state.isWorking)
        case .updateAvailable:
            Button("Update") { Task { await package.install(harness) } }
                .buttonStyle(.borderedProminent)
                .disabled(!package.isAvailable || state.isWorking)
        case .installed:
            Button {} label: { Label("Installed", systemImage: "checkmark.circle.fill") }
                .disabled(true)
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
                .disabled(relayBusy)
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
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("From anywhere")
                Text("Scribe Relay").font(.subheadline).foregroundStyle(.secondary)
            }
        } footer: {
            Text("For ChatGPT and Claude on the web, which connect from their own cloud. Transcripts pass through the relay only while an assistant is reading them. The relay never stores them.")
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
                .disabled(validAddress == nil)
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
                .disabled(relayBusy)
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
            if !relayText.isEmpty {
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

    // MARK: - ChatGPT and Claude

    private func clientSection(_ client: AssistantClient) -> some View {
        Section(client.addTitle) {
            HStack {
                Button("\(client.addTitle)…") { add(to: client) }
                    .buttonStyle(.borderedProminent)
                    .disabled(validAddress == nil)
                Spacer()
                confirmation(for: ["\(client.name) URL"])
            }
            if validAddress == nil {
                Text("Enter the relay address in Relay Settings above first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            steps(for: client)
        }
    }

    private func add(to client: AssistantClient) {
        guard let server = validAddress else { return }
        copy(server.endpoint, label: "\(client.name) URL")
        NSWorkspace.shared.open(client.setupPage)
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
}
