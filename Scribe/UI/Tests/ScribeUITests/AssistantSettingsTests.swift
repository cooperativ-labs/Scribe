import Assist
import Platform
@testable import ScribeUI
import XCTest

final class AssistantSettingsTests: XCTestCase {
    func testAssistantSectionOpensTheAssistantsTab() {
        XCTAssertEqual(SettingsTab(containing: .assistant), .assistants)
        XCTAssertEqual(SettingsTab(containing: .dictation), .dictation)
        XCTAssertEqual(SettingsTab(containing: .vocabulary), .transcription)
    }

    func testBothSegmentsAreLabelledAndDescribed() {
        XCTAssertEqual(AssistantsPane.allCases.map(\.title), ["Voice Assistant", "Transcript Access"])
        for pane in AssistantsPane.allCases {
            XCTAssertFalse(pane.summary.isEmpty)
        }
    }
}

@MainActor
final class VoiceAssistantAccountTests: XCTestCase {
    private let models = [
        AssistModel(slug: "gpt-6-sol", displayName: "GPT-6 Sol"),
        AssistModel(slug: "gpt-6-luna-light", displayName: "GPT-6 Luna (light)"),
    ]

    func testModelChoiceDefaultsToLunaLightThenKeepsThePersonsChoice() {
        XCTAssertEqual(VoiceAssistantAccount.modelChoice(current: nil, in: models)?.slug, "gpt-6-luna-light")
        XCTAssertEqual(VoiceAssistantAccount.modelChoice(current: "gpt-6-sol", in: models)?.slug, "gpt-6-sol")
        XCTAssertEqual(VoiceAssistantAccount.modelChoice(current: nil, in: [models[0]])?.slug, "gpt-6-sol")
    }

    func testAModelThatIsNoLongerOfferedIsNotSilentlyReplaced() {
        XCTAssertNil(VoiceAssistantAccount.modelChoice(current: "gpt-5-codex", in: models))
    }

    func testNoAssistantUntilTheChosenAccountIsSetUp() throws {
        let suiteName = "VoiceAssistantAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        let stores = Dictionary(uniqueKeysWithValues: AssistProvider.allCases.map { ($0, InMemorySecretStore()) })
        let account = VoiceAssistantAccount(
            session: ChatGPTSession(store: InMemorySecretStore()),
            apiKeyStore: { stores[$0]! }
        )

        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertFalse(account.isReady(settings: settings))

        settings.assistantAccountType = .apiKey
        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertEqual(account.setupMessage(settings: settings), "Add your OpenAI API key to use Voice Assistant.")
        try stores[.openAI]!.write(Data("sk-test".utf8), for: OpenAIKeyAssistant.keychainAccount)
        let assistant = try XCTUnwrap(account.makeAssistant(settings: settings) as? OpenAIKeyAssistant)
        XCTAssertEqual(assistant.model, "gpt-5-mini")

        // Each provider has its own key and its own model.
        settings.assistantAPIProvider = AssistProvider.anthropic.rawValue
        XCTAssertNil(account.makeAssistant(settings: settings))
        try stores[.anthropic]!.write(Data("sk-ant-test".utf8), for: OpenAIKeyAssistant.keychainAccount)
        let claude = try XCTUnwrap(account.makeAssistant(settings: settings) as? AnthropicAssistant)
        XCTAssertEqual(claude.model, AssistProvider.anthropic.defaultModel)
        account.chooseAPIModel("claude-sonnet-5", for: .anthropic, settings: settings)
        XCTAssertEqual(account.makeAssistant(settings: settings)?.displayName, "Anthropic")
        XCTAssertEqual(account.modelName(settings: settings), "claude-sonnet-5")
        XCTAssertEqual(VoiceAssistantAccount.apiModel(for: .openAI, settings: settings), "gpt-5-mini")

        settings.assistantAPIProvider = AssistProvider.openAI.rawValue
        account.removeAPIKey(for: .openAI)
        XCTAssertNil(try stores[.openAI]!.read(OpenAIKeyAssistant.keychainAccount))
        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertNotNil(try stores[.anthropic]!.read(OpenAIKeyAssistant.keychainAccount))
    }

    func testPrivateCloudComputeIsNotOfferedToAnUnentitledBuild() throws {
        let suiteName = "VoiceAssistantAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        let account = VoiceAssistantAccount(session: ChatGPTSession(store: InMemorySecretStore()), apiKeyStore: { _ in InMemorySecretStore() })
        settings.assistantAccountType = .privateCloud
        account.refreshPrivateCloudStatus()

        // The test runner lacks Apple's entitlement (or macOS 27), so the
        // account explains why instead of sending a request that would fail.
        XCTAssertNotEqual(account.privateCloudStatus, .available)
        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertFalse(account.isReady(settings: settings))
        XCTAssertEqual(account.setupMessage(settings: settings), account.privateCloudStatus.message)
        XCTAssertEqual(account.modelName(settings: settings), "Apple Private Cloud Compute")
    }

    func testACustomEndpointNeedsAURLAndAModelButNoKey() throws {
        let suiteName = "VoiceAssistantAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        let stores = Dictionary(uniqueKeysWithValues: AssistProvider.allCases.map { ($0, InMemorySecretStore()) })
        let account = VoiceAssistantAccount(
            session: ChatGPTSession(store: InMemorySecretStore()),
            apiKeyStore: { stores[$0]! }
        )
        settings.assistantAccountType = .apiKey
        settings.assistantAPIProvider = AssistProvider.custom.rawValue

        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertFalse(account.isReady(settings: settings))
        XCTAssertEqual(account.setupMessage(settings: settings), "Enter your endpoint’s base URL to use Voice Assistant.")
        XCTAssertNil(account.modelName(settings: settings))

        // A half-typed address is not a server yet.
        account.setCustomEndpointURL("localhost:11434", settings: settings)
        XCTAssertNil(VoiceAssistantAccount.customEndpointURL(settings: settings))
        XCTAssertNil(account.makeAssistant(settings: settings))

        account.setCustomEndpointURL("http://localhost:11434/v1/", settings: settings)
        XCTAssertEqual(VoiceAssistantAccount.customEndpointURL(settings: settings)?.absoluteString, "http://localhost:11434/v1")
        XCTAssertNil(account.makeAssistant(settings: settings), "no model chosen yet")
        XCTAssertEqual(account.setupMessage(settings: settings), "Choose a model on your endpoint to use Voice Assistant.")

        account.chooseAPIModel("llama3.2", for: .custom, settings: settings)
        XCTAssertTrue(account.isReady(settings: settings))
        let assistant = try XCTUnwrap(account.makeAssistant(settings: settings) as? ChatCompletionsAssistant)
        XCTAssertEqual(assistant.provider, .custom)
        XCTAssertEqual(assistant.model, "llama3.2")
        XCTAssertEqual(assistant.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(assistant.displayName, "localhost")
        XCTAssertEqual(account.modelName(settings: settings), "llama3.2")
        XCTAssertNil(try stores[.custom]!.read(OpenAIKeyAssistant.keychainAccount), "no key was ever saved")

        // The other providers still need a key.
        settings.assistantAPIProvider = AssistProvider.groq.rawValue
        XCTAssertFalse(account.isReady(settings: settings))
        XCTAssertNil(account.makeAssistant(settings: settings))
    }

    func testSwitchingCustomEndpointsClearsThePreviousServersModel() throws {
        let suiteName = "VoiceAssistantAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        let account = VoiceAssistantAccount(
            session: ChatGPTSession(store: InMemorySecretStore()),
            apiKeyStore: { _ in InMemorySecretStore() }
        )
        settings.assistantAccountType = .apiKey
        settings.assistantAPIProvider = AssistProvider.custom.rawValue
        account.setCustomEndpointURL("http://localhost:11434/v1", settings: settings)
        account.chooseAPIModel("server-a-model", for: .custom, settings: settings)
        account.chooseAPIModel("another-provider-model", for: .anthropic, settings: settings)
        XCTAssertTrue(account.isReady(settings: settings))

        account.setCustomEndpointURL("http://localhost:11434/v1", settings: settings)
        XCTAssertEqual(VoiceAssistantAccount.apiModel(for: .custom, settings: settings), "server-a-model")

        account.setCustomEndpointURL("http://localhost:1234/v1", settings: settings)
        XCTAssertNil(settings.assistantAPIModels[AssistProvider.custom.rawValue])
        XCTAssertEqual(settings.assistantAPIModels[AssistProvider.anthropic.rawValue], "another-provider-model")
        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertNil(account.modelName(settings: settings))
        XCTAssertFalse(account.isReady(settings: settings))
        XCTAssertEqual(account.setupMessage(settings: settings), "Choose a model on your endpoint to use Voice Assistant.")

        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertNil(relaunched.assistantAPIModels[AssistProvider.custom.rawValue])
        XCTAssertEqual(relaunched.assistantCustomEndpointURL, "http://localhost:1234/v1")
    }

    func testAnUnknownStoredProviderFallsBackToOpenAI() throws {
        let suiteName = "VoiceAssistantAccountTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        settings.assistantAPIProvider = "retired-lab"
        XCTAssertEqual(VoiceAssistantAccount.provider(settings: settings), .openAI)
    }

    func testTheConnectedMessageSaysWhenAServerListsNoModels() {
        XCTAssertEqual(VoiceAssistantSettingsView.connectedMessage(count: 3, provider: .openAI), "The key works. 3 models available.")
        XCTAssertEqual(VoiceAssistantSettingsView.connectedMessage(count: 3, provider: .custom), "Connected. 3 models available.")
        XCTAssertEqual(VoiceAssistantSettingsView.connectedMessage(count: 0, provider: .custom), "Connected, but the server lists no models. Type a model ID below.")
    }

    func testSourceLimitChoicesIncludeAnUnusualStoredValue() {
        XCTAssertEqual(VoiceAssistantSettingsView.sourceLimitChoices(including: 40_000), [10_000, 20_000, 40_000, 80_000, 160_000])
        XCTAssertEqual(VoiceAssistantSettingsView.sourceLimitChoices(including: 55_000), [10_000, 20_000, 40_000, 55_000, 80_000, 160_000])
    }
}
