import AppKit
import Assist
import Platform
import SwiftUI

/// The Voice Assistant half of the Assistants tab: hold a key, say what you
/// want, and Scribe writes the answer where the cursor is.
///
/// It follows the tab's existing pattern, a status row with an icon, a headline
/// and one sentence, then the single action, and shares the dictation model and
/// the Microphone and Accessibility gates with the Dictation tab. Account,
/// Model, Sources, Result and Advanced are laid out but not yet active: the
/// assistant has no account to send to until sign-in exists.
struct VoiceAssistantSettingsView: View {
    @ObservedObject var settings: ScribeSettings
    @ObservedObject var modelInstaller: TranscriptionModelInstaller
    @ObservedObject var account: VoiceAssistantAccount
    let permissions: PermissionService?
    /// Switches Settings to the Dictation tab, where the model and the other key live.
    let showDictation: () -> Void
    @State private var access = DictationAccess.current()
    @State private var apiKeyDraft = ""
    @State private var codeCopied = false
    @State private var showsAdvanced = false

    private var isModelInstalled: Bool { modelInstaller.state == .installed }

    var body: some View {
        Form {
            statusSection
                .id(SettingsSection.assistant)
            keySection
            accountSection
            modelSection
            sourcesSection
            resultSection
            advancedSection
        }
        .formStyle(.grouped)
        .task { await account.load(settings: settings) }
        .task {
            while !Task.isCancelled {
                access = permissions?.dictationAccess() ?? DictationAccess.current()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                statusIcon
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.assistantEnabled ? "Hold \(settings.assistantActivationKey.shortName) and speak" : "Voice Assistant is off")
                        .font(.headline)
                    Text("Sends the instruction you speak, your selection or copied text, and the text visible in the front app’s windows to the account below. Audio never leaves your Mac, and nothing is kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("Enable Voice Assistant", isOn: $settings.assistantEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!isModelInstalled && !settings.assistantEnabled)
            }
            .padding(.vertical, 4)
            .onChange(of: settings.assistantEnabled) {
                guard settings.assistantEnabled else { return }
                Task { access = await permissions?.requestDictationAccess() ?? DictationAccess.current() }
            }

            HStack {
                Label(
                    "Transcription model: \(isModelInstalled ? "Installed" : "Not installed")",
                    systemImage: isModelInstalled ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                Spacer()
                if !isModelInstalled {
                    Button("Download in Dictation…", action: showDictation)
                }
            }
            PermissionStatusRow(name: "Microphone", allowed: access.microphone == .granted, pane: .microphone, permissions: permissions)
            PermissionStatusRow(name: "Accessibility", allowed: access.accessibility, pane: .accessibility, permissions: permissions)
            if settings.assistantEnabled && !account.isReady(settings: settings) {
                Text(settings.assistantAccountType == .chatGPT
                    ? "Sign in to ChatGPT below so Voice Assistant has an account to send to."
                    : "Add an OpenAI API key below so Voice Assistant has an account to send to.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if settings.assistantEnabled && !access.isReady {
                Text("Voice Assistant will start when access is granted.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if settings.assistantEnabled && settings.dictationSecureInputBlocked {
                Text("Voice Assistant is paused while Secure Keyboard Entry is on")
                    .foregroundStyle(.orange)
            }
            if !isModelInstalled {
                Text("Voice Assistant uses the dictation model to understand what you say. Download it in Dictation to turn this on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if !settings.assistantEnabled {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
        } else if access.isReady && isModelInstalled && account.isReady(settings: settings) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    // MARK: - Key

    private var keySection: some View {
        Section {
            ActivationKeyPicker(
                title: "Assistant key",
                selection: $settings.assistantActivationKey,
                heldKey: settings.dictationActivationKey,
                heldBy: "dictation"
            )
            if settings.assistantKeyWasMoved {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        "Voice Assistant now uses \(settings.assistantActivationKey.displayName), because Dictation uses \(settings.dictationActivationKey.displayName).",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK") { settings.dismissAssistantKeyNotice() }
                        .controlSize(.small)
                }
            }
            ActivationKeyNotes(key: settings.assistantActivationKey, otherKey: settings.dictationActivationKey)
            if settings.assistantEnabled {
                if settings.assistantKeyObserved {
                    Label("\(settings.assistantActivationKey.shortName) detected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Press \(settings.assistantActivationKey.displayName) to check the assistant key. If it is not detected, check your keyboard’s modifier-key mapping.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("Hold \(settings.assistantActivationKey.displayName), say what you want, and release. Double-tap to keep listening; tap again to finish. Escape cancels.")
                .foregroundStyle(.secondary)
        } header: {
            Text("Assistant key")
        } footer: {
            Text("Dictation uses \(settings.dictationActivationKey.displayName). Change it in Dictation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Picker("Account", selection: $settings.assistantAccountType) {
                Text("ChatGPT account").tag(AssistantAccountType.chatGPT)
                Text("OpenAI API key").tag(AssistantAccountType.apiKey)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.assistantAccountType {
            case .chatGPT: chatGPTCard
            case .apiKey: apiKeyRows
            }
        } header: {
            Text("Account")
        } footer: {
            Group {
                switch settings.assistantAccountType {
                case .chatGPT:
                    Text("Uses your ChatGPT account the way the Codex CLI does. Usage counts against your ChatGPT plan’s Codex limits. This is not an OpenAI-documented integration.")
                case .apiKey:
                    Text("Requests are billed to your OpenAI Platform account at API rates. The key is kept in your Keychain.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Styled like the relay's link-code card: a headline and one sentence,
    /// the single action, and the code in large monospaced type while it is live.
    private var chatGPTCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.signIn == .signedIn ? "Signed in to ChatGPT" : "ChatGPT").font(.headline)
                    Text(chatGPTSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch account.signIn {
                case .signedOut:
                    Button("Sign in with ChatGPT…") { account.beginSignIn(settings: settings) }
                        .buttonStyle(.borderedProminent)
                case .requestingCode:
                    ProgressView().controlSize(.small)
                    Button("Cancel") { account.cancelSignIn() }
                case .awaitingCode:
                    Button("Cancel") { account.cancelSignIn() }
                case .signedIn:
                    Button("Sign Out") { account.signOut(settings: settings) }
                }
            }
            if case .awaitingCode(let pending) = account.signIn {
                TimelineView(.everyMinute) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            Text(pending.userCode)
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .tracking(3)
                                .textSelection(.enabled)
                                .accessibilityLabel("Sign-in code \(pending.userCode.map(String.init).joined(separator: " "))")
                            Spacer()
                            if codeCopied {
                                Label("Copied code", systemImage: "doc.on.clipboard")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }
                            Button("Copy") { copyCode(pending.userCode) }
                            Button("Open openai.com") { NSWorkspace.shared.open(pending.verificationURL) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Enter the code on the OpenAI page and sign in with your ChatGPT account. Scribe is waiting; the code expires at \(pending.expiresAt.formatted(date: .omitted, time: .shortened)).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let error = account.signInError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var chatGPTSubtitle: String {
        switch account.signIn {
        case .signedOut, .requestingCode:
            "Sign in to use your ChatGPT plan. You’ll get a code to enter on openai.com."
        case .awaitingCode:
            "Waiting for you to enter the code."
        case .signedIn:
            [settings.assistantChatGPTPlan.map { "\($0) plan" }, settings.assistantChatGPTAccountLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
                .nonEmpty ?? "Your ChatGPT account"
        }
    }

    @ViewBuilder
    private var apiKeyRows: some View {
        if account.hasAPIKey {
            HStack {
                Label("API key saved in your Keychain", systemImage: "key.fill")
                Spacer()
                Button("Test") { Task { await account.testAPIKey(settings: settings) } }
                    .disabled(account.apiKeyStatus == .testing)
                Button("Remove") { account.removeAPIKey() }
            }
        } else {
            HStack {
                SecureField("OpenAI API key", text: $apiKeyDraft, prompt: Text("sk-…"))
                    .textContentType(.password)
                    .onSubmit(saveAPIKey)
                Button("Save and Test", action: saveAPIKey)
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        switch account.apiKeyStatus {
        case .untested:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the key with OpenAI…").foregroundStyle(.secondary)
            }
            .font(.footnote)
        case .valid(let count):
            Label("The key works. \(count) models available.", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func saveAPIKey() {
        let key = apiKeyDraft
        apiKeyDraft = ""
        Task { await account.saveAPIKey(key, settings: settings) }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        withAnimation { codeCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { codeCopied = false }
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            switch settings.assistantAccountType {
            case .chatGPT:
                HStack {
                    Picker("Model", selection: chatGPTModelBinding) {
                        if settings.assistantChatGPTModel == nil {
                            Text(account.signIn == .signedIn ? "Loading…" : "Sign in to choose").tag("")
                        }
                        ForEach(account.models) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                        if let current = settings.assistantChatGPTModel, !account.models.isEmpty, !account.models.contains(where: { $0.slug == current }) {
                            Text("\(settings.assistantChatGPTModelName ?? current) (no longer offered)").tag(current)
                        } else if let current = settings.assistantChatGPTModel, account.models.isEmpty {
                            Text(settings.assistantChatGPTModelName ?? current).tag(current)
                        }
                    }
                    .disabled(account.signIn != .signedIn)
                    if account.modelsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh") { Task { await account.refreshModels(settings: settings) } }
                            .disabled(account.signIn != .signedIn)
                    }
                }
                if let error = account.modelsError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if isChosenModelGone {
                    Text("Your plan no longer offers this model. Choose another.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            case .apiKey:
                if account.apiModels.isEmpty {
                    TextField("Model", text: $settings.assistantAPIKeyModel)
                } else {
                    Picker("Model", selection: $settings.assistantAPIKeyModel) {
                        if !account.apiModels.contains(where: { $0.slug == settings.assistantAPIKeyModel }) {
                            Text(settings.assistantAPIKeyModel).tag(settings.assistantAPIKeyModel)
                        }
                        ForEach(account.apiModels) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text(settings.assistantAccountType == .chatGPT
                ? "The models your ChatGPT plan offers. GPT-6 Luna (light) is chosen when it is available."
                : "Test the key to list the models it can use.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var chatGPTModelBinding: Binding<String> {
        Binding(
            get: { settings.assistantChatGPTModel ?? "" },
            set: { slug in if !slug.isEmpty { account.chooseModel(slug, settings: settings) } }
        )
    }

    private var isChosenModelGone: Bool {
        guard let current = settings.assistantChatGPTModel, !account.models.isEmpty else { return false }
        return !account.models.contains { $0.slug == current }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section {
            sourceToggle("Selection", detail: "The text selected in the field you are typing in.", isOn: $settings.assistantUsesSelection)
            sourceToggle("Copied text", detail: "What you copied, when it is new since your last request.", isOn: $settings.assistantUsesCopiedText)
            sourceToggle("Text on screen", detail: "The text in the front app’s windows, read through Accessibility.", isOn: $settings.assistantUsesScreenText)
        } header: {
            Text("Sources")
        } footer: {
            Text("Only the sources turned on here are sent with your instruction. Password fields and Scribe’s own windows are never read.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Result

    private var resultSection: some View {
        Section("Result") {
            Picker("Result", selection: $settings.assistantResultMode) {
                Text("Insert where the cursor is").tag(AssistantResultMode.insert)
                Text("Copy to the clipboard only").tag(AssistantResultMode.copyOnly)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Instructions for the model")
                        Spacer()
                        Button("Reset") { settings.assistantSystemPrompt = nil }
                            .disabled(settings.assistantSystemPrompt == nil)
                    }
                    TextEditor(text: systemPromptBinding)
                        .font(.callout)
                        .frame(height: 140)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("\(AssistPrompt.applicationPlaceholder) is replaced with the front app’s name.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Source text limit", selection: $settings.assistantSourceCharacterLimit) {
                        ForEach(Self.sourceLimitChoices(including: settings.assistantSourceCharacterLimit), id: \.self) { limit in
                            Text("\(limit.formatted()) characters").tag(limit)
                        }
                    }
                    Text("Your selection is kept first, then copied text, then the screen, which is trimmed first when there is too much.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }

    private var systemPromptBinding: Binding<String> {
        Binding(
            get: { settings.assistantSystemPrompt ?? AssistPrompt.defaultSystemPrompt },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.assistantSystemPrompt = trimmed.isEmpty || text == AssistPrompt.defaultSystemPrompt ? nil : text
            }
        )
    }

    static func sourceLimitChoices(including current: Int) -> [Int] {
        Array(Set([10_000, 20_000, ScribeSettings.defaultSourceCharacterLimit, 80_000, 160_000, current])).sorted()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
