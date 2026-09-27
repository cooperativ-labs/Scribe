import Foundation
import Platform
import XCTest

private final class MockLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus
    var registerCallCount = 0
    var unregisterCallCount = 0
    var registrationError: Error?
    var unregistrationError: Error?

    init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registrationError { throw registrationError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
}

@MainActor
final class ScribeSettingsTests: XCTestCase {
    func testLivePreviewDefaultsOffAndPersists() throws {
        let suite = "LivePreviewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertFalse(settings.dictationLivePreview)
        settings.dictationLivePreview = true
        XCTAssertTrue(ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder).dictationLivePreview)
        settings.dictationLivePreview = false
        XCTAssertFalse(ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder).dictationLivePreview)
    }

    func testDictationKeyPersistsAndUnknownValuesFallBackToRightCommand() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(settings.dictationActivationKey, .rightCommand)
        for key in DictationActivationKey.allCases {
            settings.dictationActivationKey = key
            let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
            XCTAssertEqual(relaunched.dictationActivationKey, key)
        }
        settings.noteDictationKey()
        XCTAssertTrue(settings.dictationKeyObserved)
        settings.dictationActivationKey = .rightShift
        XCTAssertFalse(settings.dictationKeyObserved)
        defaults.set("unknown", forKey: "scribe.settings.dictation.activationKey")
        let recovered = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(recovered.dictationActivationKey, .rightCommand)
    }

    func testAssistantDefaultsOffOnRightShiftAndPersists() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertFalse(settings.assistantEnabled)
        XCTAssertEqual(settings.assistantActivationKey, .rightShift)
        XCTAssertEqual(settings.assistantsPane, .voiceAssistant)
        XCTAssertFalse(settings.assistantKeyWasMoved)

        settings.assistantEnabled = true
        settings.assistantActivationKey = .functionControl
        settings.assistantsPane = .transcriptAccess
        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertTrue(relaunched.assistantEnabled)
        XCTAssertEqual(relaunched.assistantActivationKey, .functionControl)
        XCTAssertEqual(relaunched.assistantsPane, .transcriptAccess)

        settings.noteAssistantKey()
        XCTAssertTrue(settings.assistantKeyObserved)
        settings.assistantActivationKey = .leftOption
        XCTAssertFalse(settings.assistantKeyObserved)
    }

    func testAssistantAccountSourcesAndPromptDefaultsPersist() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(settings.assistantAccountType, .chatGPT)
        XCTAssertNil(settings.assistantChatGPTModel)
        XCTAssertEqual(settings.assistantAPIKeyModel, "gpt-5-mini")
        XCTAssertTrue(settings.assistantUsesSelection)
        XCTAssertTrue(settings.assistantUsesCopiedText)
        XCTAssertTrue(settings.assistantUsesScreenText)
        XCTAssertEqual(settings.assistantResultMode, .insert)
        XCTAssertEqual(settings.assistantSourceCharacterLimit, 40_000)
        XCTAssertNil(settings.assistantSystemPrompt)

        settings.assistantAccountType = .apiKey
        settings.assistantChatGPTModel = "gpt-6-luna-light"
        settings.assistantChatGPTModelName = "GPT-6 Luna (light)"
        settings.assistantAPIKeyModel = "gpt-6-luna"
        settings.assistantUsesScreenText = false
        settings.assistantResultMode = .copyOnly
        settings.assistantSourceCharacterLimit = 1_000_000
        XCTAssertEqual(settings.assistantSourceCharacterLimit, 200_000)
        settings.assistantSystemPrompt = "Be brief."

        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(relaunched.assistantAccountType, .apiKey)
        XCTAssertEqual(relaunched.assistantChatGPTModel, "gpt-6-luna-light")
        XCTAssertEqual(relaunched.assistantChatGPTModelName, "GPT-6 Luna (light)")
        XCTAssertEqual(relaunched.assistantAPIKeyModel, "gpt-6-luna")
        XCTAssertFalse(relaunched.assistantUsesScreenText)
        XCTAssertEqual(relaunched.assistantResultMode, .copyOnly)
        XCTAssertEqual(relaunched.assistantSourceCharacterLimit, 200_000)
        XCTAssertEqual(relaunched.assistantSystemPrompt, "Be brief.")

        // Nothing secret is ever written to the settings domain.
        let stored = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(stored.keys.contains { $0.localizedCaseInsensitiveContains("token") || $0.localizedCaseInsensitiveContains("secret") })
    }

    func testAssistantKeyNeverMatchesTheDictationKey() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)

        // Choosing the dictation key for the assistant is refused.
        settings.assistantActivationKey = .rightCommand
        XCTAssertEqual(settings.assistantActivationKey, .rightShift)
        XCTAssertNotEqual(defaults.string(forKey: "scribe.settings.assistant.activationKey"), "rightCommand")

        // Moving dictation onto the assistant key moves the assistant to the first free entry.
        settings.dictationActivationKey = .rightShift
        XCTAssertEqual(settings.assistantActivationKey, .rightCommand)
        XCTAssertTrue(settings.assistantKeyWasMoved)
        settings.dismissAssistantKeyNotice()
        XCTAssertFalse(settings.assistantKeyWasMoved)
        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(relaunched.dictationActivationKey, .rightShift)
        XCTAssertEqual(relaunched.assistantActivationKey, .rightCommand)
    }

    func testStoredClashMovesTheAssistantKeyOnLoad() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // An older build whose dictation key is Right Shift, and no assistant key
        // stored: the default starts on the first free entry without a notice.
        defaults.set("rightShift", forKey: "scribe.settings.dictation.activationKey")
        let upgraded = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(upgraded.assistantActivationKey, .rightCommand)
        XCTAssertFalse(upgraded.assistantKeyWasMoved)

        // An edited plist that stores the same key for both: dictation keeps
        // it, the assistant moves, and the move is kept and reported.
        defaults.set("rightCommand", forKey: "scribe.settings.dictation.activationKey")
        defaults.set("rightCommand", forKey: "scribe.settings.assistant.activationKey")
        let clashed = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        XCTAssertEqual(clashed.dictationActivationKey, .rightCommand)
        XCTAssertEqual(clashed.assistantActivationKey, .rightShift)
        XCTAssertTrue(clashed.assistantKeyWasMoved)
        XCTAssertEqual(defaults.string(forKey: "scribe.settings.assistant.activationKey"), "rightShift")
        XCTAssertFalse(ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder).assistantKeyWasMoved)
    }

    func testConnectedAgentFoldersSurviveRelaunchMostRecentFirst() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeAgentFolders-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("scribe", isDirectory: true)
        let second = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: root)
        settings.connectAgentFolder(first)
        settings.connectAgentFolder(second)
        XCTAssertEqual(settings.agentFolderURLs, [second.standardizedFileURL, first.standardizedFileURL])

        // Connecting one again moves it to the front rather than listing it twice.
        settings.connectAgentFolder(first)
        XCTAssertEqual(settings.agentFolderURLs, [first.standardizedFileURL, second.standardizedFileURL])

        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: root)
        XCTAssertEqual(relaunched.agentFolderURLs, [first.standardizedFileURL, second.standardizedFileURL])

        relaunched.disconnectAgentFolder(first)
        XCTAssertEqual(relaunched.agentFolderURLs, [second.standardizedFileURL])
        // Disconnecting forgets the folder; it must not remove it from disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let afterRemoval = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: root)
        XCTAssertEqual(afterRemoval.agentFolderURLs, [second.standardizedFileURL])
    }

    func testAnAgentFolderThatHasGoneIsDroppedAtTheNextLaunch() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeAgentFolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let settings = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        settings.connectAgentFolder(folder)
        XCTAssertEqual(settings.agentFolderURLs, [folder.standardizedFileURL])

        try FileManager.default.removeItem(at: folder)

        let relaunched = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertTrue(relaunched.agentFolderURLs.isEmpty)
    }

    func testRecordingsFolderBookmarkSurvivesRelaunch() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScribeSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder)
        try firstLaunch.setRecordingsFolder(folder)
        XCTAssertNotNil(defaults.data(forKey: "scribe.settings.recordingsFolderBookmark"))

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(secondLaunch.recordingsFolderURL, folder.standardizedFileURL)
    }

    func testOtherSettingsPersistAcrossInstances() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        firstLaunch.rememberedApplicationBundleIdentifier = "us.zoom.xos"
        firstLaunch.rememberedMicrophoneID = "BuiltInMicrophoneDevice"
        firstLaunch.rememberedRecordingMode = .microphoneOnly
        firstLaunch.startShortcut = GlobalShortcut(keyCode: 18, modifiers: 256)
        firstLaunch.pasteTimestampShortcut = GlobalShortcut(keyCode: 17, modifiers: 256)
        firstLaunch.transcribeWhenFinalRecordingIsReady = true
        firstLaunch.keepRecordingFilesForDebugging = true
        firstLaunch.transcriptionSpeakerCount = .known(2)

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(secondLaunch.rememberedApplicationBundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(secondLaunch.rememberedMicrophoneID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(secondLaunch.rememberedRecordingMode, .microphoneOnly)
        XCTAssertEqual(secondLaunch.startShortcut, GlobalShortcut(keyCode: 18, modifiers: 256))
        XCTAssertEqual(secondLaunch.pasteTimestampShortcut, GlobalShortcut(keyCode: 17, modifiers: 256))
        XCTAssertTrue(secondLaunch.transcribeWhenFinalRecordingIsReady)
        XCTAssertTrue(secondLaunch.keepRecordingFilesForDebugging)
        XCTAssertEqual(secondLaunch.transcriptionSpeakerCount, .known(2))
    }

    func testRecordingFilesAreDeletedByDefaultUnlessDebugRetentionWasEnabled() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertFalse(firstLaunch.keepRecordingFilesForDebugging)

        firstLaunch.keepRecordingFilesForDebugging = true
        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertTrue(secondLaunch.keepRecordingFilesForDebugging)
    }

    func testLaunchAtLoginUsesSystemServiceAndCanBeToggled() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = MockLoginItemManager()
        let settings = ScribeSettings(
            defaults: defaults,
            defaultRecordingsFolderURL: FileManager.default.temporaryDirectory,
            loginItemManager: manager
        )

        XCTAssertFalse(settings.launchAtLogin)
        settings.setLaunchAtLogin(true)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(manager.registerCallCount, 1)

        settings.setLaunchAtLogin(false)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(manager.unregisterCallCount, 1)
    }

    func testLaunchAtLoginRegistrationFailureIsShownAndDoesNotEnableToggle() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = MockLoginItemManager()
        manager.registrationError = NSError(domain: "ScribeSettingsTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Registration failed"
        ])
        let settings = ScribeSettings(
            defaults: defaults,
            defaultRecordingsFolderURL: FileManager.default.temporaryDirectory,
            loginItemManager: manager
        )

        settings.setLaunchAtLogin(true)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginError, "Registration failed")
    }

    func testFirstRunSetupCompletionPersistsAcrossLaunches() throws {
        let suiteName = "ScribeSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory

        let firstLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder, loginItemManager: MockLoginItemManager())
        XCTAssertFalse(firstLaunch.hasCompletedFirstRunSetup)

        firstLaunch.markFirstRunSetupCompleted()
        XCTAssertTrue(firstLaunch.hasCompletedFirstRunSetup)

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: folder, loginItemManager: MockLoginItemManager())
        XCTAssertTrue(secondLaunch.hasCompletedFirstRunSetup)
    }
}
