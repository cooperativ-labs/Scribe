import AppKit
import Assist
import Platform
import SwiftUI

/// The Voice Assistant half of the Assistants tab: hold a key, say what you
/// want, and Scribe writes the answer where the cursor is.
///
/// It follows the tab's existing pattern, a status row with an icon, a headline
/// and one sentence, then the single action, and shares the dictation model and
/// the Microphone and Accessibility gates with the Dictation tab.
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
                    Text("Sends the instruction you speak and your enabled text sources to the account below. Audio stays on your Mac. Codex can use your connected tools when ChatGPT is selected.")
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
                Text(account.setupMessage(settings: settings))
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
                Text("API key").tag(AssistantAccountType.apiKey)
                Text("On this Mac").tag(AssistantAccountType.onDevice)
                if showsPrivateCloud {
                    Text("Private Cloud").tag(AssistantAccountType.privateCloud)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.assistantAccountType {
            case .chatGPT: chatGPTCard
            case .apiKey: apiKeyRows
            case .onDevice: onDeviceCard
            case .privateCloud: privateCloudCard
            }
        } header: {
            Text("Account")
        } footer: {
            Group {
                switch settings.assistantAccountType {
                case .chatGPT:
                    Text("Runs through the Codex App Server using your ChatGPT plan and connected Codex tools. It can use local Codex memory when enabled; ChatGPT saved memory is separate. Sign-in and sign-out also affect other Codex clients on this Mac.")
                case .apiKey:
                    Text(apiKeyFooter)
                case .onDevice:
                    Text("Uses Apple’s on-device foundation model. Nothing leaves your Mac and nothing is billed. The model is small and reads only a few thousand words, so long screen text is shortened, and answers are simpler than a cloud model’s.")
                case .privateCloud:
                    Text("Uses the larger Apple Intelligence model on Apple’s Private Cloud Compute servers. Your request leaves your Mac for Apple’s servers, which Apple says do not store it or make it accessible to Apple. There is no key or bill, but Apple sets a usage limit. It reads far more text than the on-device model, so long screen text is rarely shortened.")
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
                    Text(account.signIn == .signedIn ? "ChatGPT connected through Codex" : "ChatGPT through Codex").font(.headline)
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
                        .disabled(account.codex.executableURL == nil)
                case .requestingCode:
                    ProgressView().controlSize(.small)
                    Button("Cancel") { account.cancelSignIn() }
                case .awaitingCode:
                    Button("Cancel") { account.cancelSignIn() }
                case .signedIn:
                    Button("Sign Out of Codex") { account.signOut(settings: settings) }
                }
            }
            if case .awaitingCode(let pending) = account.signIn {
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
                        Text("Enter the code on the OpenAI page and sign in with your ChatGPT account. Scribe is waiting for Codex to finish sign-in.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    private var provider: AssistProvider { VoiceAssistantAccount.provider(settings: settings) }

    private var providerBinding: Binding<AssistProvider> {
        Binding(
            get: { provider },
            set: { newValue in
                apiKeyDraft = ""
                settings.assistantAPIProvider = newValue.rawValue
            }
        )
    }

    private var apiKeyFooter: String {
        if provider.isCustom {
            return "Sends requests in OpenAI’s Chat Completions format to the server above: Ollama or LM Studio on this Mac, or a company gateway. A server off this Mac must use https. The key is only needed when the server asks for one, and is kept in your Keychain."
        }
        let billing = provider.isGateway
            ? "Requests are billed to your \(provider.displayName) account, which routes them to the model’s lab."
            : "Requests are billed to your \(provider.displayName) account at API rates."
        return "\(billing) Each provider’s key is kept in your Keychain."
    }

    /// The custom endpoint's URL, nil until it is one requests can go to.
    private var customEndpointURL: URL? { VoiceAssistantAccount.customEndpointURL(settings: settings) }

    /// The server's host while the URL is usable, for the status lines.
    private var customEndpointName: String { customEndpointURL?.host() ?? "the endpoint" }

    private var customEndpointBinding: Binding<String> {
        Binding(
            get: { settings.assistantCustomEndpointURL },
            set: { account.setCustomEndpointURL($0, settings: settings) }
        )
    }

    private static func providerTitle(_ provider: AssistProvider) -> String {
        provider.isCustom ? "Custom OpenAI-compatible endpoint" : provider.displayName
    }

    @ViewBuilder
    private var apiKeyRows: some View {
        Picker("Provider", selection: providerBinding) {
            ForEach(AssistProvider.allCases) { provider in
                Text(account.hasAPIKey(for: provider) ? "\(Self.providerTitle(provider)) · key saved" : Self.providerTitle(provider))
                    .tag(provider)
            }
        }
        if provider.isCustom {
            TextField("Base URL", text: customEndpointBinding, prompt: Text(AssistProvider.custom.baseURL.absoluteString))
                .textContentType(.URL)
                .autocorrectionDisabled()
                .onSubmit(saveAPIKey)
            if !settings.assistantCustomEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, customEndpointURL == nil {
                Label("Use HTTPS for remote servers. HTTP is allowed only for localhost or a loopback IP address. The address usually ends in /v1.", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        if account.hasAPIKey(for: provider) {
            HStack {
                Label("\(provider.displayName) key saved in your Keychain", systemImage: "key.fill")
                Spacer()
                Button("Test") { Task { await account.testAPIKey(for: provider, settings: settings) } }
                    .disabled(account.status(for: provider) == .testing || (provider.isCustom && customEndpointURL == nil))
                Button("Remove") { account.removeAPIKey(for: provider) }
            }
        } else {
            let draftIsEmpty = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            HStack {
                SecureField("\(provider.displayName) API key", text: $apiKeyDraft, prompt: Text(provider.keyPlaceholder))
                    .textContentType(.password)
                    .onSubmit(saveAPIKey)
                // With no key to save, a custom endpoint's button only tests the connection.
                Button(draftIsEmpty && provider.keyIsOptional ? "Test" : "Save and Test", action: saveAPIKey)
                    .disabled(provider.isCustom ? customEndpointURL == nil || account.status(for: provider) == .testing : draftIsEmpty)
            }
            if let keysURL = provider.keysURL {
                Link("Get a \(provider.displayName) API key", destination: keysURL)
                    .font(.footnote)
            }
        }
        switch account.status(for: provider) {
        case .untested:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(provider.isCustom ? "Connecting to \(customEndpointName)…" : "Checking the key with \(provider.displayName)…")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        case .valid(let count):
            Label(Self.connectedMessage(count: count, provider: provider), systemImage: count == 0 ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(count == 0 ? .orange : .secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var onDeviceCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.onDeviceStatus == .available ? "apple.intelligence" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(account.onDeviceStatus == .available ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Intelligence").font(.headline)
                Text(account.onDeviceStatus.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if account.onDeviceStatus == .appleIntelligenceNotEnabled {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else if account.onDeviceStatus != .available && account.onDeviceStatus != .unsupportedSystem && account.onDeviceStatus != .deviceNotEligible {
                Button("Check Again") { account.refreshOnDeviceStatus() }
            }
        }
        .onAppear { account.refreshOnDeviceStatus() }
    }

    /// Offered from macOS 27, or on an older system while it is still the
    /// chosen account, so the choice stays visible with its reason.
    private var showsPrivateCloud: Bool {
        account.privateCloudStatus != .unsupportedSystem || settings.assistantAccountType == .privateCloud
    }

    private var privateCloudCard: some View {
        let status = account.privateCloudStatus
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .available ? "apple.intelligence" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(status == .available ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Private Cloud Compute").font(.headline)
                Text(status.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if account.privateCloudApproachingLimit {
                    Text("You are close to your usage limit.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            let limited = if case .limitReached = status { true } else { false }
            if status == .systemNotReady {
                VStack(alignment: .trailing) {
                    Button("Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Check Again") { account.refreshPrivateCloudStatus() }
                }
            } else if (limited || account.privateCloudApproachingLimit) && account.privateCloudCanIncreaseLimit {
                Button("Increase Limit…") { PrivateCloudModel.showLimitIncrease() }
            } else if limited {
                Button("Check Again") { account.refreshPrivateCloudStatus() }
            }
        }
        .onAppear { account.refreshPrivateCloudStatus() }
    }

    /// Saves the typed key and tests it; for a custom endpoint with no key
    /// typed, only tests the connection.
    private func saveAPIKey() {
        let key = apiKeyDraft
        let provider = provider
        apiKeyDraft = ""
        Task { await account.saveAPIKey(key, for: provider, settings: settings) }
    }

    /// What a successful test says. A local server with nothing loaded lists
    /// no models, which is worth saying since the model must then be typed.
    static func connectedMessage(count: Int, provider: AssistProvider) -> String {
        guard provider.isCustom else { return "The key works. \(count) models available." }
        return count == 0
            ? "Connected, but the server lists no models. Type a model ID below."
            : "Connected. \(count) models available."
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
                let models = account.apiModels[provider] ?? []
                if models.isEmpty {
                    TextField("Model", text: apiModelBinding, prompt: Text(provider.defaultModel.isEmpty ? "e.g. llama3.2" : provider.defaultModel))
                } else {
                    Picker("Model", selection: apiModelBinding) {
                        if !models.contains(where: { $0.slug == apiModelBinding.wrappedValue }) {
                            Text(apiModelBinding.wrappedValue).tag(apiModelBinding.wrappedValue)
                        }
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                }
            case .onDevice:
                LabeledContent("Model", value: "Apple on-device model")
            case .privateCloud:
                LabeledContent("Model", value: "Apple Private Cloud Compute model")
            }
        } header: {
            Text("Model")
        } footer: {
            Text(modelFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var modelFooter: String {
        switch settings.assistantAccountType {
        case .chatGPT: "The models your ChatGPT plan offers. GPT-6 Luna (light) is chosen when it is available."
        case .apiKey: provider.isCustom
            ? "Test the connection to list the models the server has, or type a model ID."
            : "Test the key to list the models it can use, or type a model ID."
        case .onDevice: "The model that comes with Apple Intelligence. It updates with macOS."
        case .privateCloud: "The server model behind Apple Intelligence. Apple updates it on its servers."
        }
    }

    private var apiModelBinding: Binding<String> {
        Binding(
            get: { VoiceAssistantAccount.apiModel(for: provider, settings: settings) },
            set: { account.chooseAPIModel($0, for: provider, settings: settings) }
        )
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
