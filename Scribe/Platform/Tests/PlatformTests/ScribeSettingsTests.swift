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
        firstLaunch.copyTimestampShortcut = GlobalShortcut(keyCode: 17, modifiers: 256)
        firstLaunch.transcribeWhenFinalRecordingIsReady = true
        firstLaunch.transcriptionSpeakerCount = .known(2)

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(secondLaunch.rememberedApplicationBundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(secondLaunch.rememberedMicrophoneID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(secondLaunch.rememberedRecordingMode, .microphoneOnly)
        XCTAssertEqual(secondLaunch.startShortcut, GlobalShortcut(keyCode: 18, modifiers: 256))
        XCTAssertEqual(secondLaunch.copyTimestampShortcut, GlobalShortcut(keyCode: 17, modifiers: 256))
        XCTAssertTrue(secondLaunch.transcribeWhenFinalRecordingIsReady)
        XCTAssertEqual(secondLaunch.transcriptionSpeakerCount, .known(2))
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
}
