import AppKit
import Platform
import PlatformTestSupport
import XCTest
@testable import ScribeUI

/// Builds what the status item's panel lists and inspects it.
///
/// The panel is a window rather than an `NSMenu` so it can appear over another
/// app's full-screen Space; these tests hold the content to what the menu used
/// to say, without putting a window on screen.
@MainActor
final class ScribeMenuBarControllerTests: XCTestCase {
    func testTheTransportIsNotRepeatedAsTextCommands() {
        let controller = makeController(MockRecordingCoordinator(snapshot: readySnapshot()))

        let titles = controller.makeContent().titles

        // The transport row replaced these; two ways to start a recording in
        // one panel is one too many.
        XCTAssertFalse(titles.contains("Start Recording"))
        XCTAssertFalse(titles.contains("Stop Recording"))
        XCTAssertEqual(controller.state.presentation.transport, .idle)
    }

    func testTheStatusRowAppearsOnceRecordingAndFollowsTheClock() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = RecorderMenuModel(coordinator: coordinator, now: { now })
        let controller = makeController(coordinator, model: model)

        // The Record button already says the recorder is ready.
        XCTAssertFalse(controller.makeContent().titles.contains("Idle"))

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(83)
        model.refreshPresentation()

        XCTAssertTrue(controller.makeContent().titles.contains("Recording — 01:23"))
        XCTAssertEqual(model.presentation.transport, .running)
    }

    func testTheApplicationListFillsInOnceSourcesAreEnumerated() async throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedApplications = [
            CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom"),
            CaptureApplicationOption(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams"),
        ]
        let model = RecorderMenuModel(coordinator: coordinator)
        let controller = makeController(coordinator, model: model)

        // Opening asks for the sources; the answer arrives afterwards.
        model.menuDidAppear()
        await coordinator.waitUntilIdle()
        model.menuDidDisappear()

        let applications = try XCTUnwrap(controller.makeContent().choices(titled: "Application"))
        XCTAssertEqual(applications.options.map(\.title), ["Choose…", "Zoom", "Microsoft Teams"])
    }

    func testTheChosenSourceIsTheSelectedOption() async throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedMicrophones = [
            CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone"),
            CaptureMicrophoneOption(uniqueID: "mic-2", name: "Podcast Microphone"),
        ]
        let controller = makeController(coordinator)
        coordinator.submit(.refreshSources)
        coordinator.submit(.selectMicrophone("mic-2"))
        await coordinator.waitUntilIdle()

        let microphones = try XCTUnwrap(controller.makeContent().choices(titled: "Microphone"))
        XCTAssertEqual(microphones.options.filter(\.isSelected).map(\.title), ["Podcast Microphone"])
        XCTAssertEqual(microphones.summary, "Podcast Microphone")
    }

    func testChoosingAnOptionSubmitsTheSelection() async throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let controller = makeController(coordinator)

        let modes = try XCTUnwrap(controller.makeContent().choices(titled: "Recording Mode"))
        try XCTUnwrap(modes.options.first { $0.title == "Microphone Only" }).select()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(
            controller.makeContent().choices(titled: "Recording Mode")?.options.filter(\.isSelected).map(\.title),
            ["Microphone Only"]
        )
    }

    func testRecordingModePickerMakesMicrophoneOnlyDiscoverable() throws {
        var snapshot = readySnapshot()
        snapshot.recordingMode = .microphoneOnly
        let controller = makeController(MockRecordingCoordinator(snapshot: snapshot))

        let content = controller.makeContent()

        XCTAssertTrue(content.titles.contains("Microphone-only recording — no application needed"))
        XCTAssertNil(content.choices(titled: "Application"))
        let modes = try XCTUnwrap(content.choices(titled: "Recording Mode"))
        XCTAssertEqual(modes.options.filter(\.isSelected).map(\.title), ["Microphone Only"])
    }

    func testARememberedMicrophoneThatIsGoneKeepsItsOwnSelectedOption() async throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.submit(.selectMicrophone("USB-Podmic-01"))
        await coordinator.waitUntilIdle()
        let controller = makeController(coordinator)

        let microphones = try XCTUnwrap(controller.makeContent().choices(titled: "Microphone"))

        // Capture binds the chosen device and never substitutes another, so the
        // panel must not show the default as chosen instead.
        XCTAssertEqual(microphones.options.map(\.title), ["System Default", "USB-Podmic-01 (not connected)"])
        XCTAssertEqual(microphones.options.filter(\.isSelected).map(\.title), ["USB-Podmic-01 (not connected)"])
    }

    func testPasteTimestampShowsItsShortcutAndIsEnabledWhileRecording() async throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let controller = makeController(coordinator)

        let idle = try XCTUnwrap(controller.makeContent().command(titled: "Paste Timestamp"))
        XCTAssertFalse(idle.isEnabled)
        XCTAssertEqual(idle.shortcut, GlobalShortcut.defaultPasteTimestamp.displayName)

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        let recording = try XCTUnwrap(controller.makeContent().command(titled: "Paste Timestamp"))
        XCTAssertTrue(recording.isEnabled)
    }

    func testPasteTimestampWritesTheElapsedFigure() async {
        let start = Date(timeIntervalSince1970: 1_000)
        var now = start
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { now })
        let model = RecorderMenuModel(coordinator: coordinator, now: { now })
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(83)

        model.pasteTimestamp()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.pastedTimestamps, ["at 01:23"])
        XCTAssertEqual(coordinator.performedCommands, [.start, .pasteTimestamp])
    }

    func testTheStatusItemWearsARedDotWhileRecordingWithoutTheChip() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = RecorderMenuModel(coordinator: coordinator)
        let controller = makeController(coordinator, model: model)

        XCTAssertFalse(controller.showsRecordingIndicator)

        // The chip is on screen for the first seconds of a recording it started,
        // and says the same thing the dot would; only one of them says it.
        controller.isMeetingChipVisible = true
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertFalse(controller.showsRecordingIndicator)

        controller.isMeetingChipVisible = false
        XCTAssertTrue(controller.showsRecordingIndicator)

        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()
        XCTAssertFalse(controller.showsRecordingIndicator)
    }

    func testOpenTranscriptionsFolderAppearsBesideOpenRecordingsFolder() throws {
        var openedTranscriptions = false
        let controller = makeController(
            MockRecordingCoordinator(snapshot: readySnapshot()),
            transcription: TranscriptionMenuCommands(
                openTranscripts: {},
                transcribeFolder: {},
                openTranscriptionsFolder: { openedTranscriptions = true }
            )
        )

        let content = controller.makeContent()

        let titles = content.titles
        let transcriptionsIndex = try XCTUnwrap(titles.firstIndex(of: "Open Transcriptions Folder"))
        let recordingsIndex = try XCTUnwrap(titles.firstIndex(of: "Open Recordings Folder"))
        XCTAssertEqual(transcriptionsIndex + 1, recordingsIndex)

        try XCTUnwrap(content.command(titled: "Open Transcriptions Folder")).perform()
        XCTAssertTrue(openedTranscriptions)
    }

    func testOpenTranscriptionsFolderIsAbsentWithoutTranscription() {
        let controller = makeController(MockRecordingCoordinator(snapshot: readySnapshot()))

        let titles = controller.makeContent().titles

        XCTAssertFalse(titles.contains("Open Transcriptions Folder"))
        XCTAssertTrue(titles.contains("Open Recordings Folder"))
    }

    func testDictationRowsReflectTheSetting() throws {
        var enabled = true
        let controller = makeController(MockRecordingCoordinator(snapshot: readySnapshot()))
        controller.dictationEnabled = { enabled }
        controller.toggleDictation = { enabled.toggle() }
        controller.dictationSecureInputBlocked = { true }

        let on = try XCTUnwrap(controller.makeContent().command(titled: "Dictation: On"))
        XCTAssertEqual(on.isOn, true)
        XCTAssertTrue(controller.makeContent().titles.contains("Dictation is paused while Secure Keyboard Entry is on"))

        on.perform()

        XCTAssertEqual(controller.makeContent().command(titled: "Dictation: Off")?.isOn, false)
    }

    func testRecordingFailuresOmitDiagnosticText() {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.simulateFailure(
            RecorderFailure(
                code: "capture.failed",
                message: "The meeting app stopped sharing audio.",
                recoveryHint: "Try again."
            )
        )
        let controller = makeController(coordinator)

        let titles = controller.makeContent().titles

        XCTAssertTrue(titles.contains("Recording failed"))
        XCTAssertFalse(titles.contains { $0.contains("stopped sharing") })
        XCTAssertFalse(titles.contains { $0.contains("Try again") })
    }

    func testTranscriptionFailuresAreNotListed() {
        let controller = makeController(
            MockRecordingCoordinator(snapshot: readySnapshot()),
            transcription: TranscriptionMenuCommands(
                failure: "Transcription of weekly-sync.flac failed: model missing",
                openTranscripts: {},
                transcribeFolder: {},
                openTranscriptionsFolder: {}
            )
        )

        let titles = controller.makeContent().titles

        XCTAssertFalse(titles.contains { $0.contains("model missing") })
        XCTAssertTrue(titles.contains("Transcripts…"))
    }

    func testUpdateFailuresShowAShortStatusInsteadOfTheDiagnostic() {
        let controller = makeController(
            MockRecordingCoordinator(snapshot: readySnapshot()),
            updates: UpdateMenuCommands(
                state: .failed(message: "The download could not be verified: signature mismatch on Scribe.zip"),
                checkForUpdates: {},
                installUpdate: {}
            )
        )

        let titles = controller.makeContent().titles

        XCTAssertTrue(titles.contains("Update failed"))
        XCTAssertFalse(titles.contains { $0.contains("signature mismatch") })
    }

    func testAFoundUpdateIsShownDownloadingWithNoManualDownloadCommand() {
        let controller = makeController(
            MockRecordingCoordinator(snapshot: readySnapshot()),
            updates: UpdateMenuCommands(
                state: .downloading(version: "1.2.3"),
                checkForUpdates: {},
                installUpdate: {}
            )
        )

        let titles = controller.makeContent().titles

        XCTAssertTrue(titles.contains("Downloading Scribe 1.2.3…"))
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("Download Update") })
        XCTAssertFalse(titles.contains("Check for Updates…"))
    }

    func testThePanelCanJoinFullScreenSpaces() {
        let controller = makeController(MockRecordingCoordinator(snapshot: readySnapshot()))
        let panel = StatusMenuPanel()

        // The reason the status item opens a panel at all: an `NSMenu` from a
        // Dock app is not shown over another app's full-screen Space.
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(controller.isPanelShown)
    }

    // MARK: Helpers

    private func makeController(
        _ coordinator: MockRecordingCoordinator,
        model: RecorderMenuModel? = nil,
        transcription: TranscriptionMenuCommands? = nil,
        updates: UpdateMenuCommands? = nil
    ) -> ScribeMenuBarController {
        ScribeMenuBarController(
            model: model ?? RecorderMenuModel(coordinator: coordinator),
            image: nil,
            accessibilityLabel: "Scribe",
            transcription: { transcription },
            updates: { updates },
            openSettings: {}
        )
    }
}
