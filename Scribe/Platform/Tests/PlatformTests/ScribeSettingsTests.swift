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

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(secondLaunch.rememberedApplicationBundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(secondLaunch.rememberedMicrophoneID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(secondLaunch.rememberedRecordingMode, .microphoneOnly)
        XCTAssertEqual(secondLaunch.startShortcut, GlobalShortcut(keyCode: 18, modifiers: 256))
        XCTAssertEqual(secondLaunch.copyTimestampShortcut, GlobalShortcut(keyCode: 17, modifiers: 256))
        XCTAssertTrue(secondLaunch.transcribeWhenFinalRecordingIsReady)
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
