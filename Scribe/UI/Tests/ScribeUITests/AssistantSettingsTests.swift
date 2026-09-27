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
        let keys = InMemorySecretStore()
        let account = VoiceAssistantAccount(
            session: ChatGPTSession(store: InMemorySecretStore()),
            apiKeyStore: keys
        )

        XCTAssertNil(account.makeAssistant(settings: settings))
        XCTAssertFalse(account.isReady(settings: settings))

        settings.assistantAccountType = .apiKey
        XCTAssertNil(account.makeAssistant(settings: settings))
        try keys.write(Data("sk-test".utf8), for: OpenAIKeyAssistant.keychainAccount)
        let assistant = try XCTUnwrap(account.makeAssistant(settings: settings) as? OpenAIKeyAssistant)
        XCTAssertEqual(assistant.model, "gpt-5-mini")

        account.removeAPIKey()
        XCTAssertNil(try keys.read(OpenAIKeyAssistant.keychainAccount))
        XCTAssertNil(account.makeAssistant(settings: settings))
    }

    func testSourceLimitChoicesIncludeAnUnusualStoredValue() {
        XCTAssertEqual(VoiceAssistantSettingsView.sourceLimitChoices(including: 40_000), [10_000, 20_000, 40_000, 80_000, 160_000])
        XCTAssertEqual(VoiceAssistantSettingsView.sourceLimitChoices(including: 55_000), [10_000, 20_000, 40_000, 55_000, 80_000, 160_000])
    }
}
