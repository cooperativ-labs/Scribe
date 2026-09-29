import Assist
import Foundation
import Platform

/// The voice assistant's account as Settings shows it: the ChatGPT sign-in,
/// the model list, the API key for each provider, and Apple's models on this
/// Mac and on Private Cloud Compute.
///
/// Codex manages its ChatGPT credential and connected tools. API provider keys
/// remain in Scribe's Keychain. Settings cache only display labels and models.
@MainActor
public final class VoiceAssistantAccount: ObservableObject {
    public static let shared = VoiceAssistantAccount()

    public enum SignInState: Equatable {
        case signedOut
        case requestingCode
        case awaitingCode(CodexDeviceCode)
        case signedIn
    }

    public enum APIKeyStatus: Equatable {
        case untested
        case testing
        case valid(modelCount: Int)
        case failed(String)
    }

    @Published public private(set) var signIn: SignInState = .signedOut
    @Published public private(set) var signInError: String?
    @Published public private(set) var models: [AssistModel] = []
    @Published public private(set) var modelsLoading = false
    @Published public private(set) var modelsError: String?
    /// The providers with a key saved in the Keychain.
    @Published public private(set) var providersWithKeys: Set<AssistProvider> = []
    @Published public private(set) var apiKeyStatus: [AssistProvider: APIKeyStatus] = [:]
    @Published public private(set) var apiModels: [AssistProvider: [AssistModel]] = [:]
    @Published public private(set) var onDeviceStatus: OnDeviceModel.Status = .unsupportedSystem
    @Published public private(set) var privateCloudStatus: PrivateCloudModel.Status = .unsupportedSystem
    /// Whether the Private Cloud Compute quota is nearly used up.
    @Published public private(set) var privateCloudApproachingLimit = false
    /// Whether Apple offers a way to raise the Private Cloud Compute quota.
    @Published public private(set) var privateCloudCanIncreaseLimit = false

    let codex: CodexAppServer
    private let apiKeyStore: @Sendable (AssistProvider) -> SecretStore
    private var signInTask: Task<Void, Never>?
    private var signInGeneration = 0
    private var loaded = false
    private var customEndpointRevision = 0

    init(
        codex: CodexAppServer = CodexAppServer(),
        apiKeyStore: @escaping @Sendable (AssistProvider) -> SecretStore = { KeychainStore(service: $0.keychainService) }
    ) {
        self.codex = codex
        self.apiKeyStore = apiKeyStore
    }

    /// Reads what is stored, once per launch, and fetches the model list when
    /// signed in and none is loaded yet.
    public func load(settings: ScribeSettings) async {
        if !loaded {
            loaded = true
            providersWithKeys = Set(AssistProvider.allCases.filter {
                (try? apiKeyStore($0).contains(OpenAIKeyAssistant.keychainAccount)) ?? false
            })
        }
        if signInTask == nil {
            do {
                if let account = try await codex.account() {
                    setSignedIn(account, settings: settings)
                } else {
                    clearSignedIn(settings: settings)
                }
            } catch {
                clearSignedIn(settings: settings)
                signInError = error.localizedDescription
            }
        }
        onDeviceStatus = OnDeviceModel.status
        refreshPrivateCloudStatus()
        if signIn == .signedIn, models.isEmpty, !modelsLoading {
            await refreshModels(settings: settings)
        }
    }

    /// Checks Apple Intelligence again, e.g. after the person turns it on.
    public func refreshOnDeviceStatus() {
        onDeviceStatus = OnDeviceModel.status
    }

    /// Checks Private Cloud Compute again: availability, entitlement and quota.
    public func refreshPrivateCloudStatus() {
        privateCloudStatus = PrivateCloudModel.status
        privateCloudApproachingLimit = privateCloudStatus == .available && PrivateCloudModel.isApproachingLimit
        privateCloudCanIncreaseLimit = PrivateCloudModel.canIncreaseLimit
    }

    // MARK: Codex-managed ChatGPT sign-in

    public func beginSignIn(settings: ScribeSettings) {
        signInTask?.cancel()
        signInGeneration += 1
        let generation = signInGeneration
        signInError = nil
        signIn = .requestingCode
        signInTask = Task { [self] in
            defer { if signInGeneration == generation { signInTask = nil } }
            do {
                let signedInAccount = try await codex.signIn { pending in
                    await MainActor.run {
                        if self.signInGeneration == generation { self.signIn = .awaitingCode(pending) }
                    }
                }
                guard signInGeneration == generation else { return }
                setSignedIn(signedInAccount, settings: settings)
                await refreshModels(settings: settings)
            } catch is CancellationError {
                if signInGeneration == generation { signIn = .signedOut }
            } catch {
                guard signInGeneration == generation else { return }
                guard !Task.isCancelled else { signIn = .signedOut; return }
                signInError = error.localizedDescription
                signIn = .signedOut
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInGeneration += 1
        signInTask = nil
        signIn = .signedOut
    }

    public func signOut(settings: ScribeSettings) {
        signInTask?.cancel()
        signInGeneration += 1
        signInTask = nil
        signIn = .signedOut
        Task {
            do {
                try await codex.signOut()
                signInError = nil
            } catch {
                signInError = error.localizedDescription
            }
            if let account = try? await codex.account() {
                setSignedIn(account, settings: settings)
            } else {
                clearSignedIn(settings: settings)
                models = []
                modelsError = nil
            }
        }
    }

    /// Loads the account's models and fills in the default choice when none is made.
    public func refreshModels(settings: ScribeSettings) async {
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            models = try await codex.models()
            modelsError = nil
            if let choice = Self.modelChoice(current: settings.assistantChatGPTModel, in: models) {
                settings.assistantChatGPTModel = choice.slug
                settings.assistantChatGPTModelName = choice.displayName
            }
        } catch {
            modelsError = error.localizedDescription
        }
    }

    private func setSignedIn(_ account: CodexAccount, settings: ScribeSettings) {
        settings.assistantChatGPTPlan = account.planName
        settings.assistantChatGPTAccountLabel = account.email
        signIn = .signedIn
        signInError = nil
    }

    private func clearSignedIn(settings: ScribeSettings) {
        signIn = .signedOut
        settings.assistantChatGPTPlan = nil
        settings.assistantChatGPTAccountLabel = nil
    }

    /// The model to select after a list loads: the current one while it is
    /// listed, the default when none is chosen, and nil (keep the current,
    /// shown as no longer offered) when a chosen model has gone.
    nonisolated static func modelChoice(current: String?, in models: [AssistModel]) -> AssistModel? {
        if let current, !current.isEmpty {
            return models.first { $0.slug == current }
        }
        return AssistModel.preferredDefault(in: models)
    }

    public func chooseModel(_ slug: String, settings: ScribeSettings) {
        settings.assistantChatGPTModel = slug
        settings.assistantChatGPTModelName = models.first { $0.slug == slug }?.displayName ?? slug
    }

    // MARK: API keys

    /// The provider the settings name, OpenAI when the stored value is unknown.
    public static func provider(settings: ScribeSettings) -> AssistProvider {
        AssistProvider(rawValue: settings.assistantAPIProvider) ?? .openAI
    }

    /// The model the provider is sent: the person's choice, else its default.
    public static func apiModel(for provider: AssistProvider, settings: ScribeSettings) -> String {
        settings.assistantAPIModels[provider.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
    }

    public func chooseAPIModel(_ slug: String, for provider: AssistProvider, settings: ScribeSettings) {
        settings.assistantAPIModels[provider.rawValue] = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func hasAPIKey(for provider: AssistProvider) -> Bool {
        providersWithKeys.contains(provider)
    }

    public func status(for provider: AssistProvider) -> APIKeyStatus {
        apiKeyStatus[provider] ?? .untested
    }

    /// Stores the key and tests it. An empty key only tests the connection,
    /// for a custom endpoint that needs none.
    public func saveAPIKey(_ key: String, for provider: AssistProvider, settings: ScribeSettings) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard provider.keyIsOptional else { return }
            await testAPIKey(for: provider, settings: settings)
            return
        }
        do {
            try apiKeyStore(provider).write(Data(trimmed.utf8), for: OpenAIKeyAssistant.keychainAccount)
            providersWithKeys.insert(provider)
            await testAPIKey(for: provider, settings: settings)
        } catch {
            apiKeyStatus[provider] = .failed(error.localizedDescription)
        }
    }

    public func removeAPIKey(for provider: AssistProvider) {
        do {
            try apiKeyStore(provider).delete(OpenAIKeyAssistant.keychainAccount)
            providersWithKeys.remove(provider)
            apiKeyStatus[provider] = nil
            apiModels[provider] = nil
        } catch {
            apiKeyStatus[provider] = .failed(error.localizedDescription)
        }
    }

    /// Lists the key's models: proves the key works and fills the picker.
    /// When the person has not chosen a model and the provider no longer
    /// lists its default, the first listed model is chosen instead.
    public func testAPIKey(for provider: AssistProvider, settings: ScribeSettings) async {
        guard let assistant = apiAssistant(for: provider, settings: settings) else {
            apiKeyStatus[provider] = .failed(
                provider.isCustom ? "Enter the endpoint’s base URL first, e.g. \(AssistProvider.custom.baseURL.absoluteString)." : "No API key is saved."
            )
            return
        }
        let endpointRevision = customEndpointRevision
        apiKeyStatus[provider] = .testing
        do {
            let models = try await assistant.availableModels()
            guard !provider.isCustom || endpointRevision == customEndpointRevision else { return }
            apiModels[provider] = models
            apiKeyStatus[provider] = .valid(modelCount: models.count)
            if settings.assistantAPIModels[provider.rawValue] == nil,
               !models.contains(where: { $0.slug == provider.defaultModel }),
               let first = models.first {
                chooseAPIModel(first.slug, for: provider, settings: settings)
            }
        } catch {
            guard !provider.isCustom || endpointRevision == customEndpointRevision else { return }
            apiKeyStatus[provider] = .failed(error.localizedDescription)
        }
    }

    private func storedAPIKey(for provider: AssistProvider) -> String? {
        (try? apiKeyStore(provider).read(OpenAIKeyAssistant.keychainAccount)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Custom endpoint

    /// The server the custom endpoint sends to, nil until a usable URL is typed.
    public static func customEndpointURL(settings: ScribeSettings) -> URL? {
        AssistProvider.customBaseURL(settings.assistantCustomEndpointURL)
    }

    /// Stores the typed URL. A different server has different models, so the
    /// list, model choice, and last test result no longer apply.
    public func setCustomEndpointURL(_ text: String, settings: ScribeSettings) {
        guard text != settings.assistantCustomEndpointURL else { return }
        customEndpointRevision += 1
        settings.assistantCustomEndpointURL = text
        settings.assistantAPIModels[AssistProvider.custom.rawValue] = nil
        apiModels[.custom] = nil
        apiKeyStatus[.custom] = nil
    }

    /// The API-key assistant the settings describe for `provider`: nil without
    /// a key, or, for the custom endpoint, without a usable URL. Its model may
    /// still be empty for a custom endpoint whose models are not listed yet.
    private func apiAssistant(for provider: AssistProvider, settings: ScribeSettings) -> (any APIKeyAssistant)? {
        guard let key = storedAPIKey(for: provider) ?? (provider.keyIsOptional ? "" : nil) else { return nil }
        var baseURL: URL?
        if provider.isCustom {
            guard let url = Self.customEndpointURL(settings: settings) else { return nil }
            baseURL = url
        }
        let model = Self.apiModel(for: provider, settings: settings)
        return provider.makeAssistant(
            apiKey: key,
            model: model,
            systemPrompt: settings.assistantSystemPrompt,
            maxOutputTokens: apiModels[provider]?.first { $0.slug == model }?.maxOutputTokens,
            baseURL: baseURL
        )
    }

    // MARK: For the coordinator

    /// The assistant the current settings describe, or nil when the chosen
    /// account is not set up.
    public func makeAssistant(settings: ScribeSettings) -> TextAssistant? {
        switch settings.assistantAccountType {
        case .chatGPT:
            guard signIn == .signedIn, let model = settings.assistantChatGPTModel else { return nil }
            return CodexAppServerAssistant(
                server: codex, model: model, systemPrompt: settings.assistantSystemPrompt,
                requestInput: { questions in await CodexToolApprovalPresenter.answer(questions) }
            )
        case .apiKey:
            guard let assistant = apiAssistant(for: Self.provider(settings: settings), settings: settings), !assistant.model.isEmpty else { return nil }
            return assistant
        case .onDevice:
            guard OnDeviceModel.status == .available else { return nil }
            return AppleIntelligenceAssistant(systemPrompt: settings.assistantSystemPrompt)
        case .privateCloud:
            // A used-up quota still sends, so the answer is the system's own
            // message and the request succeeds once the quota resets.
            switch PrivateCloudModel.status {
            case .available, .limitReached: return PrivateCloudAssistant(systemPrompt: settings.assistantSystemPrompt)
            default: return nil
            }
        }
    }

    /// The model name the indicator shows for the chosen account.
    public func modelName(settings: ScribeSettings) -> String? {
        switch settings.assistantAccountType {
        case .chatGPT:
            return settings.assistantChatGPTModelName ?? settings.assistantChatGPTModel
        case .apiKey:
            let provider = Self.provider(settings: settings)
            let slug = Self.apiModel(for: provider, settings: settings)
            guard !slug.isEmpty else { return nil }
            return apiModels[provider]?.first { $0.slug == slug }?.displayName ?? slug
        case .onDevice:
            return "Apple on-device model"
        case .privateCloud:
            return "Apple Private Cloud Compute"
        }
    }

    /// Why the chosen account cannot take a request, for the indicator and Settings.
    public func setupMessage(settings: ScribeSettings) -> String {
        switch settings.assistantAccountType {
        case .chatGPT:
            return codex.executableURL == nil
                ? "Install the Codex CLI to use connected tools in Voice Assistant."
                : "Sign in to ChatGPT through Codex to use Voice Assistant."
        case .apiKey:
            let provider = Self.provider(settings: settings)
            guard provider.isCustom else { return "Add your \(provider.displayName) API key to use Voice Assistant." }
            if Self.customEndpointURL(settings: settings) == nil {
                return "Enter your endpoint’s base URL to use Voice Assistant."
            }
            return "Choose a model on your endpoint to use Voice Assistant."
        case .onDevice:
            return OnDeviceModel.status.message
        case .privateCloud:
            return PrivateCloudModel.status.message
        }
    }

    /// Whether the chosen account can take a request, for the status row.
    func isReady(settings: ScribeSettings) -> Bool {
        switch settings.assistantAccountType {
        case .chatGPT:
            return signIn == .signedIn && settings.assistantChatGPTModel != nil
        case .apiKey:
            let provider = Self.provider(settings: settings)
            guard provider.isCustom else { return hasAPIKey(for: provider) }
            return Self.customEndpointURL(settings: settings) != nil && !Self.apiModel(for: provider, settings: settings).isEmpty
        case .onDevice:
            return onDeviceStatus == .available
        case .privateCloud:
            return privateCloudStatus == .available
        }
    }
}
