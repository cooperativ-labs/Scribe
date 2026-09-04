import Platform
import XCTest

@MainActor
final class MockRecordingCoordinatorTests: XCTestCase {
    func testStartWhileRecordingIsHarmless() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        guard case .recording(let first) = coordinator.snapshot.state else {
            return XCTFail("expected recording, got \(coordinator.snapshot.state)")
        }

        coordinator.submit(.start)
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        guard case .recording(let current) = coordinator.snapshot.state else {
            return XCTFail("expected the first recording to still be running")
        }
        XCTAssertEqual(current.sessionID, first.sessionID)
        // The redundant commands were accepted and then deliberately ignored.
        XCTAssertEqual(coordinator.acceptedCommands, [.start, .start, .start])
        XCTAssertEqual(coordinator.performedCommands, [.start])
    }

    func testStopWhileIdleIsHarmless() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())

        coordinator.submit(.stop)
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertTrue(coordinator.performedCommands.isEmpty)
        XCTAssertTrue(coordinator.snapshot.processing.jobs.isEmpty)
    }

    func testMenuAndShortcutCommandsShareOneSerializedPath() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let registrar = HotKeyRegistrarSpy()
        let hotkeys = HotkeyService(coordinator: coordinator, registrar: registrar, debounceInterval: 0)
        hotkeys.register(start: .defaultStart, stop: .defaultStop)

        // A menu start, then a shortcut stop: both land on the same queue.
        coordinator.submit(.start)
        registrar.fire(identifier: 2)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.acceptedCommands, [.start, .stop])
        XCTAssertEqual(coordinator.performedCommands, [.start, .stop])
        XCTAssertEqual(coordinator.snapshot.state, .idle)
    }

    func testStoppingHandsOffToBackgroundProcessingAndFreesTheRecorder() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        guard case .recording(let activity) = coordinator.snapshot.state else {
            return XCTFail("expected recording")
        }
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        // Capture is closed and idle even though processing is still running, so
        // the next meeting can be recorded immediately.
        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertEqual(coordinator.snapshot.processing.jobs.map(\.id), [activity.sessionID])

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.snapshot.state.isRecording)
        XCTAssertEqual(coordinator.snapshot.processing.jobs.count, 1)

        coordinator.completeBackgroundProcessing(activity.sessionID)
        XCTAssertTrue(coordinator.snapshot.processing.jobs.isEmpty)
    }

    func testTransitionalStatesAreObservable() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.holdsTransitions = true

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.snapshot.state, .starting)

        coordinator.finishPendingTransition()
        XCTAssertTrue(coordinator.snapshot.state.isRecording)

        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.snapshot.state, .stopping)

        coordinator.finishPendingTransition()
        XCTAssertEqual(coordinator.snapshot.state, .idle)
    }

    func testStartFailureIsReportedAndRecoverable() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let failure = RecorderFailure(code: "capture.unavailable", message: "No shareable audio.", recoveryHint: "Open the meeting app.")
        coordinator.startFailure = failure

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(coordinator.snapshot.state, .failed(failure))

        // A failed recorder still accepts a fresh start.
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.snapshot.state.isRecording)
    }

    func testSnapshotObserversSeeTheCurrentValueImmediately() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        var observed: [RecorderState] = []
        let token = coordinator.observeSnapshot { observed.append($0.state) }

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        token.invalidate()
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()

        // The current snapshot on subscribe, then each transition, and nothing
        // after the token was invalidated.
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[0], .idle)
        XCTAssertEqual(observed[1], .starting)
        XCTAssertTrue(observed[2].isRecording)
    }

    func testShortcutConflictsAreSurfacedWithoutDisablingTheMenu() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let registrar = HotKeyRegistrarSpy(conflictingShortcut: .defaultStop)
        let hotkeys = HotkeyService(coordinator: coordinator, registrar: registrar)

        coordinator.reportShortcutRegistration(hotkeys.register(start: .defaultStart, stop: .defaultStop))

        XCTAssertEqual(coordinator.snapshot.shortcutIssues.count, 1)
        XCTAssertTrue(coordinator.snapshot.shortcutIssues[0].hasPrefix("Stop shortcut:"))

        // The menu path is unaffected by the failed registration.
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.snapshot.state.isRecording)
    }

    func testSourcesRefreshFromTheProviderAndSelectionsPersistInTheSnapshot() async {
        let provider = CaptureSourceProviderStub(
            applications: [CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom")],
            microphones: [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")],
            systemDefaultMicrophoneID: "mic-1"
        )
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), sourceProvider: provider)

        coordinator.submit(.refreshSources)
        coordinator.submit(.selectApplication("us.zoom.xos"))
        coordinator.submit(.selectMicrophone("mic-1"))
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.applications.map(\.id), ["us.zoom.xos"])
        XCTAssertEqual(coordinator.snapshot.microphones.map(\.id), ["mic-1"])
        XCTAssertEqual(coordinator.snapshot.systemDefaultMicrophoneID, "mic-1")
        XCTAssertEqual(coordinator.snapshot.selectedApplicationID, "us.zoom.xos")
        XCTAssertEqual(coordinator.snapshot.selectedMicrophoneID, "mic-1")
    }

    func testPermissionRequestAndSettingsRoutesAreCommands() async {
        let coordinator = MockRecordingCoordinator(
            snapshot: RecorderSnapshot(permissions: PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined))
        )
        coordinator.permissionRequestResult = PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted)

        coordinator.submit(.requestPermissions)
        coordinator.submit(.openSystemSettings(.screenRecording))
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.permissionRequestCount, 1)
        XCTAssertEqual(coordinator.snapshot.permissions.microphone, .granted)
        XCTAssertEqual(coordinator.openedSettingsPanes, [.screenRecording])
        XCTAssertFalse(coordinator.snapshot.permissions.isReadyToRecord)
    }

    func testOpenRecordingsFolderUsesTheConfiguredFolder() async {
        let folder = URL(fileURLWithPath: "/tmp/scribe-recordings", isDirectory: true)
        var opened: [URL] = []
        let coordinator = MockRecordingCoordinator(
            snapshot: readySnapshot(recordingsFolderURL: folder),
            openFolder: { opened.append($0) }
        )

        coordinator.submit(.openRecordingsFolder)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(opened, [folder])
        XCTAssertEqual(coordinator.openedRecordingsFolderURLs, [folder])
    }

    func testQuittingDuringCapturePerformsANormalStopFirst() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        var terminated = false
        coordinator.terminationHandler = { terminated = true }

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        coordinator.submit(.quit)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertEqual(coordinator.snapshot.processing.jobs.count, 1, "the interrupted session is still handed to processing")
        XCTAssertTrue(terminated)
    }

    private func readySnapshot(recordingsFolderURL: URL = URL(fileURLWithPath: "/tmp/scribe", isDirectory: true)) -> RecorderSnapshot {
        RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: recordingsFolderURL)
    }
}

// MARK: - Doubles

@MainActor
private final class HotKeyRegistrarSpy: HotKeyRegistering {
    private let conflictingShortcut: GlobalShortcut?
    private var actions: [UInt32: @MainActor () -> Void] = [:]

    init(conflictingShortcut: GlobalShortcut? = nil) {
        self.conflictingShortcut = conflictingShortcut
    }

    func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws {
        if shortcut == conflictingShortcut { throw HotkeyRegistrationFailure.systemConflict(status: -9878) }
        actions[identifier] = action
    }

    func unregisterAll() { actions.removeAll() }

    func fire(identifier: UInt32) { actions[identifier]?() }
}

private struct CaptureSourceProviderStub: CaptureSourceProviding {
    let applications: [CaptureApplicationOption]
    let microphones: [CaptureMicrophoneOption]
    var systemDefaultMicrophoneID: String?

    func shareableApplications() async throws -> [CaptureApplicationOption] { applications }
    func availableMicrophones() async -> [CaptureMicrophoneOption] { microphones }
    func systemDefaultMicrophone() async -> CaptureMicrophoneOption? {
        microphones.first { $0.uniqueID == systemDefaultMicrophoneID }
    }
}
