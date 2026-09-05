import Platform
import XCTest
@testable import ScribeUI

@MainActor
final class RecorderMenuModelTests: XCTestCase {
    func testMenuCommandsTravelTheCoordinatorPath() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = RecorderMenuModel(coordinator: coordinator)

        model.startRecording()
        model.stopRecording()
        model.openRecordingsFolder()
        model.openSystemSettings(.microphone)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.acceptedCommands, [.start, .stop, .openRecordingsFolder, .openSystemSettings(.microphone)])
    }

    func testPresentationTracksCoordinatorSnapshots() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = RecorderMenuModel(coordinator: coordinator)
        XCTAssertEqual(model.presentation.statusTitle, "Idle")

        model.startRecording()
        await coordinator.waitUntilIdle()

        XCTAssertTrue(model.presentation.isStopEnabled)
        XCTAssertTrue(model.presentation.statusTitle.hasPrefix("Recording — "))
    }

    func testElapsedTimeAdvancesWithTheClock() async {
        let start = Date(timeIntervalSince1970: 5_000)
        var now = start
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        let model = RecorderMenuModel(coordinator: coordinator, now: { now })

        model.startRecording()
        await coordinator.waitUntilIdle()
        XCTAssertEqual(model.presentation.statusTitle, "Recording — 00:00")

        now = start.addingTimeInterval(65)
        model.refreshPresentation()
        XCTAssertEqual(model.presentation.statusTitle, "Recording — 01:05")
    }

    func testTransportCommandsTravelTheCoordinatorPath() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = RecorderMenuModel(coordinator: coordinator)

        model.startRecording()
        model.pauseRecording()
        model.resumeRecording()
        model.stopRecording()
        await coordinator.waitUntilIdle()

        // The transport row is a menu command like any other: it takes the same
        // serialized route a global shortcut does.
        XCTAssertEqual(coordinator.performedCommands, [.start, .pause, .resume, .stop])
        XCTAssertEqual(model.presentation.transport, .idle)
    }

    func testSourceSelectionsAreSubmittedWithoutABinding() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedApplications = [CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom")]
        let model = RecorderMenuModel(coordinator: coordinator)

        model.selectApplication("us.zoom.xos")
        model.selectMicrophone("mic-1")
        await coordinator.waitUntilIdle()

        XCTAssertEqual(model.presentation.selectedApplicationID, "us.zoom.xos")
        XCTAssertEqual(model.presentation.selectedMicrophoneID, "mic-1")
    }

    func testOpeningTheMenuReenumeratesSources() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedApplications = [CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom")]
        coordinator.scriptedMicrophones = [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")]
        let model = RecorderMenuModel(coordinator: coordinator)
        XCTAssertTrue(model.presentation.applications.isEmpty)

        model.menuDidAppear()
        await coordinator.waitUntilIdle()
        model.menuDidDisappear()

        XCTAssertEqual(coordinator.sourceRefreshCount, 1)
        XCTAssertEqual(model.presentation.applications.map(\.name), ["Zoom"])
        XCTAssertEqual(model.presentation.microphones.map(\.name), ["Built-in Microphone"])
    }

    func testPickerSelectionsAreSubmittedAsCommands() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedApplications = [CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom")]
        coordinator.scriptedMicrophones = [CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone")]
        let model = RecorderMenuModel(coordinator: coordinator)

        model.selectedApplication.wrappedValue = "us.zoom.xos"
        model.selectedMicrophone.wrappedValue = "mic-1"
        await coordinator.waitUntilIdle()

        XCTAssertEqual(model.presentation.selectedApplicationID, "us.zoom.xos")
        XCTAssertEqual(model.presentation.selectedMicrophoneID, "mic-1")
    }

    func testRepeatedStartAndStopFromTheMenuAreHarmless() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = RecorderMenuModel(coordinator: coordinator)

        model.stopRecording()
        model.startRecording()
        model.startRecording()
        model.stopRecording()
        model.stopRecording()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.performedCommands, [.start, .stop])
        XCTAssertEqual(model.presentation.statusTitle, "Idle")
    }

    func testRequestingPermissionsUpdatesTheMenu() async {
        let coordinator = MockRecordingCoordinator(
            snapshot: RecorderSnapshot(permissions: PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .notDetermined))
        )
        let model = RecorderMenuModel(coordinator: coordinator)
        XCTAssertNotNil(model.presentation.permissionPrompt)

        model.requestPermissions()
        await coordinator.waitUntilIdle()

        XCTAssertNil(model.presentation.permissionPrompt)
        XCTAssertTrue(model.presentation.isStartEnabled)
    }

    func testQuittingStopsAnActiveRecordingFirst() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        var terminated = false
        coordinator.terminationHandler = { terminated = true }
        let model = RecorderMenuModel(coordinator: coordinator)

        model.startRecording()
        model.quit()
        await coordinator.waitUntilIdle()

        XCTAssertTrue(terminated)
        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertEqual(coordinator.snapshot.processing.jobs.count, 1)
    }

    private func readySnapshot() -> RecorderSnapshot {
        RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: URL(fileURLWithPath: "/tmp/scribe", isDirectory: true))
    }
}
