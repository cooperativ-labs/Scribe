import Foundation
import Platform
import XCTest

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
        firstLaunch.startShortcut = GlobalShortcut(keyCode: 18, modifiers: 256)
        firstLaunch.transcribeWhenFinalRecordingIsReady = true

        let secondLaunch = ScribeSettings(defaults: defaults, defaultRecordingsFolderURL: FileManager.default.temporaryDirectory)
        XCTAssertEqual(secondLaunch.rememberedApplicationBundleIdentifier, "us.zoom.xos")
        XCTAssertEqual(secondLaunch.rememberedMicrophoneID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(secondLaunch.startShortcut, GlobalShortcut(keyCode: 18, modifiers: 256))
        XCTAssertTrue(secondLaunch.transcribeWhenFinalRecordingIsReady)
    }
}
