import Platform
import XCTest
@testable import ScribeUI

/// Every menu state is produced from the mock coordinator, so the whole
/// interface is verifiable before the capture core exists.
@MainActor
final class MenuPresentationTests: XCTestCase {
    func testIdleStateOffersStartAndNotStop() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())

        let presentation = presentation(for: coordinator)

        XCTAssertEqual(presentation.statusTitle, "Idle")
        XCTAssertTrue(presentation.isStartEnabled)
        XCTAssertFalse(presentation.isStopEnabled)
        XCTAssertNil(presentation.permissionPrompt)
        XCTAssertTrue(presentation.processingLines.isEmpty)
    }

    func testStartingStateOffersNeitherCommand() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.holdsTransitions = true
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        let presentation = presentation(for: coordinator)

        XCTAssertEqual(presentation.statusTitle, "Starting…")
        XCTAssertFalse(presentation.isStartEnabled)
        XCTAssertFalse(presentation.isStopEnabled)
    }

    func testRecordingStateShowsElapsedTimeAndOffersStop() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        let presentation = MenuPresentation(snapshot: coordinator.snapshot, at: start.addingTimeInterval(83))

        XCTAssertEqual(presentation.statusTitle, "Recording — 01:23")
        XCTAssertFalse(presentation.isStartEnabled)
        XCTAssertTrue(presentation.isStopEnabled)
    }

    func testRecordingPastAnHourShowsHours() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        let presentation = MenuPresentation(snapshot: coordinator.snapshot, at: start.addingTimeInterval(3_723))

        XCTAssertEqual(presentation.statusTitle, "Recording — 1:02:03")
    }

    func testStoppingStateOffersNeitherCommand() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.holdsTransitions = true
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        coordinator.finishPendingTransition()
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        let presentation = presentation(for: coordinator)

        XCTAssertEqual(presentation.statusTitle, "Stopping…")
        XCTAssertFalse(presentation.isStartEnabled)
        XCTAssertFalse(presentation.isStopEnabled)
    }

    func testTheTransportRowOffersRecordUntilASessionExists() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        XCTAssertEqual(presentation(for: coordinator).transport, .idle)

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        // Once a session exists the row is Pause and Stop; there is no Record
        // button to press twice.
        let running = presentation(for: coordinator)
        XCTAssertEqual(running.transport, .running)
        XCTAssertTrue(running.isPauseEnabled)
        XCTAssertFalse(running.isResumeEnabled)
        XCTAssertTrue(running.isStopEnabled)
    }

    func testPausingKeepsTheSessionAndOffersResumeAndStop() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        coordinator.submit(.start)
        coordinator.submit(.pause)
        await coordinator.waitUntilIdle()

        let presentation = MenuPresentation(snapshot: coordinator.snapshot, at: start.addingTimeInterval(83))

        // The elapsed figure keeps running because the recording does: the
        // paused span is reconstructed as silence.
        XCTAssertEqual(presentation.statusTitle, "Paused — 01:23")
        XCTAssertEqual(presentation.transport, .running)
        XCTAssertTrue(presentation.isResumeEnabled)
        XCTAssertFalse(presentation.isPauseEnabled)
        // A paused session can be stopped, and must not be startable again.
        XCTAssertTrue(presentation.isStopEnabled)
        XCTAssertFalse(presentation.isStartEnabled)
    }

    func testResumingReturnsToRecordingWithoutStartingASecondSession() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        let session = coordinator.snapshot.state.activity?.sessionID

        coordinator.submit(.pause)
        coordinator.submit(.resume)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state.activity?.sessionID, session)
        XCTAssertTrue(presentation(for: coordinator).isPauseEnabled)
        XCTAssertEqual(coordinator.performedCommands, [.start, .pause, .resume])
    }

    func testStoppingKeepsTheTransportRowRatherThanOfferingRecordAgain() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.holdsTransitions = true
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        coordinator.finishPendingTransition()
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        let presentation = presentation(for: coordinator)

        // The session is still being finalized: nothing here can be pressed yet.
        XCTAssertEqual(presentation.transport, .running)
        XCTAssertFalse(presentation.isPauseEnabled)
        XCTAssertFalse(presentation.isResumeEnabled)
        XCTAssertFalse(presentation.isStopEnabled)
    }

    func testPauseAndResumeAreIgnoredWhenThereIsNoSessionToHold() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())

        coordinator.submit(.pause)
        coordinator.submit(.resume)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.performedCommands, [])
        XCTAssertEqual(coordinator.snapshot.state, .idle)
    }

    func testMissingPermissionsLeaveTheRecordButtonPresentButDisabled() {
        let snapshot = RecorderSnapshot(
            permissions: PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted)
        )

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        // A Record button that cannot be pressed still says what the menu is
        // for; replacing it with Pause and Stop would not.
        XCTAssertEqual(presentation.transport, .idle)
        XCTAssertFalse(presentation.isStartEnabled)
    }

    func testMicrophoneOnlyIsReadyWithoutScreenRecordingPermission() {
        var snapshot = readySnapshot()
        snapshot.recordingMode = .microphoneOnly
        snapshot.permissions = PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted)

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertEqual(presentation.recordingMode, .microphoneOnly)
        XCTAssertTrue(presentation.isStartEnabled)
        XCTAssertNil(presentation.permissionPrompt)
    }

    func testMicrophoneOnlyExplainsThatOnlyMicrophonePermissionIsNeeded() {
        var snapshot = readySnapshot()
        snapshot.recordingMode = .microphoneOnly
        snapshot.permissions = PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined)

        let prompt = MenuPresentation(snapshot: snapshot, at: Date()).permissionPrompt

        XCTAssertEqual(prompt?.requirements.map(\.pane), [.microphone])
    }

    func testErrorStateShowsTheFailureAndAllowsAnotherAttempt() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.simulateFailure(
            RecorderFailure(code: "capture.failed", message: "The meeting app stopped sharing audio.", recoveryHint: "Try again.")
        )

        let presentation = presentation(for: coordinator)

        XCTAssertEqual(presentation.statusTitle, "Recording failed")
        XCTAssertEqual(presentation.statusDetail, "The meeting app stopped sharing audio. Try again.")
        XCTAssertTrue(presentation.isStartEnabled)
    }

    func testBackgroundProcessingIsShownSeparatelyFromCapture() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        let presentation = presentation(for: coordinator)

        // Capture is idle and startable while processing continues.
        XCTAssertEqual(presentation.statusTitle, "Idle")
        XCTAssertTrue(presentation.isStartEnabled)
        XCTAssertEqual(presentation.processingLines, ["Processing recording…"])
    }

    func testProcessingProgressIsShownAsAPercentage() {
        var snapshot = readySnapshot()
        snapshot.processing.jobs = [
            BackgroundProcessingJob(id: UUID(), title: "Processing recording", fractionCompleted: 0.42)
        ]

        XCTAssertEqual(MenuPresentation(snapshot: snapshot, at: Date()).processingLines, ["Processing recording — 42%"])
    }

    func testRecoveryFeedbackIsShownSeparatelyFromProcessingProgress() {
        var snapshot = readySnapshot()
        snapshot.recoveryNotice = "Recovered 2 recordings from an interrupted session; finishing them now."
        snapshot.processing.jobs = [BackgroundProcessingJob(id: UUID(), title: "Processing recording")]

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertEqual(presentation.recoveryNotice, "Recovered 2 recordings from an interrupted session; finishing them now.")
        // The notice explains where the work came from; it is not a job row.
        XCTAssertEqual(presentation.processingLines, ["Processing recording…"])
        // Recovered work never blocks the next meeting.
        XCTAssertTrue(presentation.isStartEnabled)
    }

    func testABackgroundFailureIsReadWithoutAPrefixThatWouldMisnameIt() {
        var snapshot = readySnapshot()
        snapshot.processing.lastFailure = RecorderFailure(
            code: "handoff.cleanupFailed",
            message: "Audio cleanup failed, so there is no final recording to transcribe: the delay could not be trusted",
            recoveryHint: "The original tracks were kept. Reprocess the session to try again."
        )

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertEqual(presentation.processingLines, [
            "Audio cleanup failed, so there is no final recording to transcribe: the delay could not be trusted The original tracks were kept. Reprocess the session to try again."
        ])
        // A background failure is not a recording failure.
        XCTAssertEqual(presentation.statusTitle, "Idle")
        XCTAssertTrue(presentation.isStartEnabled)
    }

    func testMissingPermissionsBlockStartAndOfferBothRoutes() {
        let snapshot = RecorderSnapshot(
            permissions: PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined)
        )

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())
        let prompt = try? XCTUnwrap(presentation.permissionPrompt)

        XCTAssertFalse(presentation.isStartEnabled)
        XCTAssertEqual(prompt?.title, "Scribe needs permission to record")
        XCTAssertTrue(prompt?.canRequestInApp == true)
        // After a denial System Settings is the only way back, so it is always offered.
        XCTAssertEqual(prompt?.settingsRoutes, [.screenRecording, .microphone])
    }

    func testShortcutConflictsAreShownWithoutDisablingMenuCommands() {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let registrar = ConflictingRegistrar()
        let hotkeys = HotkeyService(coordinator: coordinator, registrar: registrar)
        coordinator.reportShortcutRegistration(hotkeys.register(start: .defaultStart, stop: .defaultStop))

        let presentation = presentation(for: coordinator)

        XCTAssertEqual(presentation.shortcutIssues.count, 3)
        XCTAssertTrue(presentation.isStartEnabled)
    }

    func testCopyTimestampIsOfferedWhileARecordingHasAnElapsedFigure() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let presentationAt: () -> MenuPresentation = {
            MenuPresentation(snapshot: coordinator.snapshot, at: now, copyTimestampShortcut: .defaultCopyTimestamp)
        }

        XCTAssertFalse(presentationAt().isCopyTimestampEnabled)

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(83)
        let recording = presentationAt()
        XCTAssertTrue(recording.isCopyTimestampEnabled)
        XCTAssertEqual(recording.copyTimestampShortcut, .defaultCopyTimestamp)
    }

    // MARK: Source pickers

    func testTheDefaultMicrophoneRowNamesTheCurrentSystemDefault() {
        var snapshot = readySnapshot()
        snapshot.microphones = [
            CaptureMicrophoneOption(uniqueID: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone"),
            CaptureMicrophoneOption(uniqueID: "USB-Podmic-01", name: "Podcast Microphone"),
        ]
        snapshot.systemDefaultMicrophoneID = "USB-Podmic-01"

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertNil(presentation.selectedMicrophoneID, "Nothing remembered means the system default is the choice.")
        XCTAssertEqual(presentation.systemDefaultMicrophoneName, "Podcast Microphone")
        XCTAssertEqual(presentation.systemDefaultMicrophoneLabel, "System Default (Podcast Microphone)")
    }

    func testTheDefaultMicrophoneRowIsPlainWhenNoDefaultIsKnown() {
        var snapshot = readySnapshot()
        snapshot.microphones = [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")]

        XCTAssertEqual(MenuPresentation(snapshot: snapshot, at: Date()).systemDefaultMicrophoneLabel, "System Default")

        // A default that is not among the listed devices is not named either:
        // the list is what the person can choose from.
        snapshot.systemDefaultMicrophoneID = "gone"
        XCTAssertEqual(MenuPresentation(snapshot: snapshot, at: Date()).systemDefaultMicrophoneLabel, "System Default")
    }

    func testARememberedSourceThatIsAbsentStaysVisibleInThePickers() {
        var snapshot = readySnapshot()
        snapshot.applications = [CaptureApplicationOption(bundleIdentifier: "com.apple.Safari", name: "Safari")]
        snapshot.microphones = [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")]
        snapshot.selectedApplicationID = "us.zoom.xos"
        snapshot.selectedMicrophoneID = "USB-Podmic-01"

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertEqual(presentation.unavailableSelectedApplication, UnavailableSource(id: "us.zoom.xos", label: "us.zoom.xos (not running)"))
        XCTAssertEqual(presentation.unavailableSelectedMicrophone, UnavailableSource(id: "USB-Podmic-01", label: "USB-Podmic-01 (not connected)"))
    }

    func testAvailableSelectionsNeedNoPlaceholderRow() {
        var snapshot = readySnapshot()
        snapshot.applications = [CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom")]
        snapshot.microphones = [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")]
        snapshot.selectedApplicationID = "us.zoom.xos"
        snapshot.selectedMicrophoneID = "mic-1"

        let presentation = MenuPresentation(snapshot: snapshot, at: Date())

        XCTAssertNil(presentation.unavailableSelectedApplication)
        XCTAssertNil(presentation.unavailableSelectedMicrophone)
        XCTAssertNil(MenuPresentation(snapshot: readySnapshot(), at: Date()).unavailableSelectedMicrophone, "The system default is never a placeholder.")
    }

    private func presentation(for coordinator: MockRecordingCoordinator) -> MenuPresentation {
        MenuPresentation(snapshot: coordinator.snapshot, at: Date())
    }

    private func readySnapshot() -> RecorderSnapshot {
        RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: URL(fileURLWithPath: "/tmp/scribe", isDirectory: true))
    }
}

@MainActor
private final class ConflictingRegistrar: HotKeyRegistering {
    func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws {
        throw HotkeyRegistrationFailure.systemConflict(status: -9878)
    }

    func unregisterAll() {}
}
