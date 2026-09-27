import Assist
import Foundation
import Platform

/// The voice assistant's account as Settings shows it: the ChatGPT sign-in,
/// the model list, and the OpenAI API key.
///
/// Secrets stay in the Keychain behind `ChatGPTSession` and the API-key store;
/// settings cache only the plan, the account label and the chosen model, so
/// opening Settings never reads a token.
@MainActor
public final class VoiceAssistantAccount: ObservableObject {
    public static let shared = VoiceAssistantAccount()

    public enum SignInState: Equatable {
        case signedOut
        case requestingCode
        case awaitingCode(DeviceSignIn)
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
    @Published public private(set) var hasAPIKey = false
    @Published public private(set) var apiKeyStatus: APIKeyStatus = .untested
    @Published public private(set) var apiModels: [AssistModel] = []

    let session: ChatGPTSession
    private let apiKeyStore: SecretStore
    private var signInTask: Task<Void, Never>?
    private var loaded = false

    init(
        session: ChatGPTSession = ChatGPTSession(),
        apiKeyStore: SecretStore = KeychainStore(service: KeychainStore.openAIService)
    ) {
        self.session = session
        self.apiKeyStore = apiKeyStore
    }

    /// Reads what is stored, once per launch, and fetches the model list when
    /// signed in and none is loaded yet.
    public func load(settings: ScribeSettings) async {
        if !loaded {
            loaded = true
            hasAPIKey = (try? apiKeyStore.contains(OpenAIKeyAssistant.keychainAccount)) ?? false
            if case .signedOut = signIn, await session.isSignedIn() {
                signIn = .signedIn
            } else if case .signedOut = signIn {
                settings.assistantChatGPTPlan = nil
                settings.assistantChatGPTAccountLabel = nil
            }
        }
        if signIn == .signedIn, models.isEmpty, !modelsLoading {
            await refreshModels(settings: settings)
        }
    }

    // MARK: ChatGPT sign-in

    public func beginSignIn(settings: ScribeSettings) {
        signInTask?.cancel()
        signInError = nil
        signIn = .requestingCode
        signInTask = Task {
            do {
                let pending = try await session.beginDeviceSignIn()
                signIn = .awaitingCode(pending)
                let account = try await session.completeDeviceSignIn(pending)
                settings.assistantChatGPTPlan = account.planName
                settings.assistantChatGPTAccountLabel = account.email ?? account.accountID
                signIn = .signedIn
                await refreshModels(settings: settings)
            } catch is CancellationError {
                signIn = .signedOut
            } catch {
                signInError = error.localizedDescription
                signIn = .signedOut
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .signedOut
    }

    public func signOut(settings: ScribeSettings) {
        signInTask?.cancel()
        Task {
            do {
                try await session.signOut()
                signInError = nil
            } catch {
                signInError = error.localizedDescription
            }
            signIn = await session.isSignedIn() ? .signedIn : .signedOut
            if signIn == .signedOut {
                settings.assistantChatGPTPlan = nil
                settings.assistantChatGPTAccountLabel = nil
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
            models = try await session.models()
            modelsError = nil
            if let choice = Self.modelChoice(current: settings.assistantChatGPTModel, in: models) {
                settings.assistantChatGPTModel = choice.slug
                settings.assistantChatGPTModelName = choice.displayName
            }
        } catch AssistError.signInRequired {
            signIn = .signedOut
            settings.assistantChatGPTPlan = nil
            settings.assistantChatGPTAccountLabel = nil
            signInError = AssistError.signInRequired.localizedDescription
        } catch {
            modelsError = error.localizedDescription
        }
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

    // MARK: OpenAI API key

    public func saveAPIKey(_ key: String, settings: ScribeSettings) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try apiKeyStore.write(Data(trimmed.utf8), for: OpenAIKeyAssistant.keychainAccount)
            hasAPIKey = true
            await testAPIKey(settings: settings)
        } catch {
            apiKeyStatus = .failed(error.localizedDescription)
        }
    }

    public func removeAPIKey() {
        do {
            try apiKeyStore.delete(OpenAIKeyAssistant.keychainAccount)
            hasAPIKey = false
            apiKeyStatus = .untested
            apiModels = []
        } catch {
            apiKeyStatus = .failed(error.localizedDescription)
        }
    }

    /// Lists the key's models: proves the key works and fills the picker.
    public func testAPIKey(settings: ScribeSettings) async {
        guard let key = storedAPIKey() else {
            apiKeyStatus = .failed("No API key is saved.")
            return
        }
        apiKeyStatus = .testing
        do {
            let models = try await OpenAIKeyAssistant(apiKey: key, model: settings.assistantAPIKeyModel).availableModels()
            apiModels = models
            apiKeyStatus = .valid(modelCount: models.count)
        } catch {
            apiKeyStatus = .failed(error.localizedDescription)
        }
    }

    private func storedAPIKey() -> String? {
        (try? apiKeyStore.read(OpenAIKeyAssistant.keychainAccount)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: For the coordinator

    /// The assistant the current settings describe, or nil when the chosen
    /// account is not set up.
    public func makeAssistant(settings: ScribeSettings) -> TextAssistant? {
        switch settings.assistantAccountType {
        case .chatGPT:
            guard signIn == .signedIn, let model = settings.assistantChatGPTModel else { return nil }
            return ChatGPTAssistant(session: session, model: model, systemPrompt: settings.assistantSystemPrompt)
        case .apiKey:
            guard let key = storedAPIKey() else { return nil }
            return OpenAIKeyAssistant(apiKey: key, model: settings.assistantAPIKeyModel, systemPrompt: settings.assistantSystemPrompt)
        }
    }

    /// Whether the chosen account can take a request, for the status row.
    func isReady(settings: ScribeSettings) -> Bool {
        switch settings.assistantAccountType {
        case .chatGPT: signIn == .signedIn && settings.assistantChatGPTModel != nil
        case .apiKey: hasAPIKey
        }
    }
}
