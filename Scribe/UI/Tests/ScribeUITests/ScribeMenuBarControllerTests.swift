import AppKit
import Platform
import XCTest
@testable import ScribeUI

/// Builds the real menu and inspects what it produced.
///
/// The two facts this has to hold to are the ones that were wrong before: the
/// transport controls are the first thing in the menu, and the source lists are
/// submenus that fill themselves in rather than being rebuilt underneath an open
/// one.
@MainActor
final class ScribeMenuBarControllerTests: XCTestCase {
    func testTheTransportRowIsTheFirstThingInTheMenu() {
        let controller = makeController(MockRecordingCoordinator(snapshot: readySnapshot()))

        controller.menuNeedsUpdate(controller.menu)

        XCTAssertTrue(controller.menu.items.first?.view is RecordingTransportView)
        // The old text commands are gone: the row above replaced them, and two
        // ways to start a recording in one menu is one too many.
        XCTAssertFalse(controller.menu.items.contains { $0.title == "Start Recording" })
        XCTAssertFalse(controller.menu.items.contains { $0.title == "Stop Recording" })
    }

    func testTheStatusRowFollowsTheRecorderWithoutRebuildingTheMenu() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = RecorderMenuModel(coordinator: coordinator, now: { now })
        let controller = makeController(coordinator, model: model)
        controller.menuNeedsUpdate(controller.menu)
        let built = controller.menu.items

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(83)
        model.refreshPresentation()

        // The elapsed time is edited into the row that is already there. Adding
        // or removing an item here is what closed an open submenu.
        XCTAssertEqual(controller.menu.items.map(\.title), built.map(\.title).enumerated().map { index, title in
            index == 1 ? "Recording — 01:23" : title
        })
    }

    func testTheApplicationSubmenuFillsItselfInWhenItIsAboutToOpen() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedApplications = [
            CaptureApplicationOption(bundleIdentifier: "us.zoom.xos", name: "Zoom"),
            CaptureApplicationOption(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams"),
        ]
        let controller = makeController(coordinator)
        controller.menuNeedsUpdate(controller.menu)

        // The menu opens before source enumeration has answered, which is why
        // the submenu is not populated with it.
        let applicationItem = controller.menu.items.first { $0.title == "Application" }
        XCTAssertTrue(applicationItem?.submenu === controller.applicationMenu)
        controller.menuWillOpen(controller.menu)
        await coordinator.waitUntilIdle()

        controller.menuNeedsUpdate(controller.applicationMenu)

        XCTAssertEqual(controller.applicationMenu.items.map(\.title), ["Choose…", "Zoom", "Microsoft Teams"])
    }

    func testTheChosenSourceIsTheCheckedRow() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.scriptedMicrophones = [
            CaptureMicrophoneOption(uniqueID: "mic-1", name: "Built-in Microphone"),
            CaptureMicrophoneOption(uniqueID: "mic-2", name: "Podcast Microphone"),
        ]
        let controller = makeController(coordinator)
        coordinator.submit(.refreshSources)
        coordinator.submit(.selectMicrophone("mic-2"))
        await coordinator.waitUntilIdle()

        controller.menuNeedsUpdate(controller.microphoneMenu)

        let checked = controller.microphoneMenu.items.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checked, ["Podcast Microphone"])
    }

    func testARememberedMicrophoneThatIsGoneKeepsItsOwnCheckedRow() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.submit(.selectMicrophone("USB-Podmic-01"))
        await coordinator.waitUntilIdle()
        let controller = makeController(coordinator)

        controller.menuNeedsUpdate(controller.microphoneMenu)

        // Capture binds the chosen device and never substitutes another, so the
        // menu must not show the default as chosen instead.
        XCTAssertEqual(controller.microphoneMenu.items.map(\.title), ["System Default", "USB-Podmic-01 (not connected)"])
        XCTAssertEqual(controller.microphoneMenu.items.filter { $0.state == .on }.map(\.title), ["USB-Podmic-01 (not connected)"])
    }

    // MARK: Helpers

    private func makeController(
        _ coordinator: MockRecordingCoordinator,
        model: RecorderMenuModel? = nil
    ) -> ScribeMenuBarController {
        ScribeMenuBarController(
            model: model ?? RecorderMenuModel(coordinator: coordinator),
            image: nil,
            accessibilityLabel: "Scribe",
            transcription: { nil },
            updates: { nil },
            openSettings: {}
        )
    }

    private func readySnapshot() -> RecorderSnapshot {
        RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: URL(fileURLWithPath: "/tmp/scribe", isDirectory: true))
    }
}
