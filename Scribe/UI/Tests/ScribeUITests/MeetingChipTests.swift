import AppKit
import Platform
import XCTest
@testable import ScribeUI

/// What the chip may say, and when it may say it.
///
/// The chip speaks first, over whatever the person is doing, so the rules about
/// when it appears matter more than how it looks: it must not ask twice, must
/// not interrupt a recording the menu started, and must not offer a Record
/// button that cannot record.
@MainActor
final class MeetingChipTests: XCTestCase {
    // MARK: The offer

    func testANoticedCallIsOfferedByName() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))

        model.meetingWasDetected(zoomCall())

        XCTAssertEqual(model.presentation, .offer(.init(applicationName: "Zoom", domain: nil)))
        guard case .offer(let offer) = model.presentation else { return XCTFail("expected an offer") }
        XCTAssertEqual(offer.question, "Record this Zoom meeting?")
    }

    func testACallWithACalendarMeetingIsOfferedByThatMeetingsName() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))

        model.meetingWasDetected(zoomCall(calendarTitle: "Weekly Sync"))

        guard case .offer(let offer) = model.presentation else { return XCTFail("expected an offer") }
        // The calendar says which meeting; the application says where it is.
        XCTAssertEqual(offer.question, "Record \u{201C}Weekly Sync\u{201D}?")
        XCTAssertEqual(offer.detail, "Zoom")
        XCTAssertEqual(
            MeetingChipPresentation.Offer(applicationName: "Arc", domain: "meet.google.com", meetingTitle: "Weekly Sync").detail,
            "meet.google.com in Arc"
        )
        XCTAssertNil(MeetingChipPresentation.Offer(applicationName: "Zoom", domain: nil).detail)
    }

    func testTheTransportNamesTheMeetingBeingRecorded() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        coordinator.nextRecordingTitle = "Weekly Sync"
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall(calendarTitle: "Weekly Sync"))

        model.record()
        await coordinator.waitUntilIdle()

        guard case .session(let session) = model.presentation else { return XCTFail("expected a session") }
        XCTAssertEqual(session.title, "Weekly Sync")
    }

    func testACallNoticedInABrowserNamesTheWebsiteAsWellAsTheBrowser() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))

        model.meetingWasDetected(browserCall(domain: "meet.google.com"))

        // The browser answers "which application"; the website answers "which of
        // my nine tabs", which is the half a person actually recognises.
        XCTAssertEqual(model.presentation, .offer(.init(applicationName: "Arc", domain: "meet.google.com")))
    }

    func testNothingIsOfferedWhilePermissionsWouldMakeRecordingFail() {
        let coordinator = MockRecordingCoordinator(snapshot: RecorderSnapshot(
            permissions: PermissionSnapshot(screenAndSystemAudio: .denied, microphone: .granted)
        ))
        let model = makeModel(coordinator)

        model.meetingWasDetected(zoomCall())

        // Offering a Record button that cannot start is worse than staying quiet:
        // the menu already explains what is missing.
        XCTAssertEqual(model.presentation, .hidden)
    }

    func testTheChipGoesAwayWhenTheCallEnds() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))
        model.meetingWasDetected(zoomCall())

        model.meetingWasDetected(nil)

        XCTAssertEqual(model.presentation, .hidden)
    }

    // MARK: Dismissal

    func testDismissingSilencesThatCallButNotTheNextOne() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))
        let call = zoomCall()
        model.meetingWasDetected(call)

        model.dismiss()
        XCTAssertEqual(model.presentation, .hidden)

        // The detector keeps reporting the same call for as long as the
        // microphone is open, and none of that may bring the chip back.
        model.meetingWasDetected(call)
        XCTAssertEqual(model.presentation, .hidden)

        // A later call is a new question.
        model.meetingWasDetected(zoomCall(at: Date(timeIntervalSince1970: 9_000)))
        XCTAssertEqual(model.presentation, .offer(.init(applicationName: "Zoom", domain: nil)))
    }

    func testADismissedBrowserCallStaysDismissedWhenItsTabChangesDomain() {
        let model = makeModel(MockRecordingCoordinator(snapshot: readySnapshot()))
        model.meetingWasDetected(browserCall(domain: "meet.google.com"))
        model.dismiss()

        // The detector republishes the same call with a new domain when the tab
        // moves; that is the same call, and the answer was already no.
        model.meetingWasDetected(browserCall(domain: "teams.microsoft.com"))

        XCTAssertEqual(model.presentation, .hidden)
    }

    // MARK: Accepting

    func testRecordingScopesTheCaptureToTheApplicationThatWasNoticed() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())

        model.record()
        await coordinator.waitUntilIdle()

        // Offering to record a Zoom call and then capturing whatever was last
        // chosen in the menu would be wrong in a way nobody would notice.
        XCTAssertEqual(coordinator.snapshot.selectedApplicationID, "us.zoom.xos")
        XCTAssertTrue(coordinator.snapshot.state.isRecording)
    }

    func testAcceptingTurnsTheChipIntoTheTransportForThatRecording() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = makeModel(coordinator, now: { now })
        model.meetingWasDetected(zoomCall())

        model.record()
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(2)
        model.refreshPresentation()

        XCTAssertEqual(model.presentation, .session(.init(
            elapsedText: "00:02",
            isPaused: false,
            isHoldEnabled: true,
            isStopEnabled: true
        )))
    }

    func testTheTransportWithdrawsThreeSecondsIntoTheRecording() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = makeModel(coordinator, now: { now })
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        now = start.addingTimeInterval(MeetingChipPresentation.sessionVisibleDuration - 0.1)
        model.refreshPresentation()
        guard case .session = model.presentation else { return XCTFail("expected the transport") }

        now = start.addingTimeInterval(MeetingChipPresentation.sessionVisibleDuration)
        model.refreshPresentation()

        // The chip's job was to say the recording started. A floating window
        // over the call for the next hour is not that, and the menu bar's red
        // dot says the same thing without taking any room.
        XCTAssertEqual(model.presentation, .hidden)

        // And it stays away: the recording running is not a reason to ask again.
        now = start.addingTimeInterval(600)
        model.refreshPresentation()
        XCTAssertEqual(model.presentation, .hidden)
    }

    func testACallNoticedWellIntoARecordingDoesNotPutTheTransportBack() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = makeModel(coordinator, now: { now })
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        now = start.addingTimeInterval(300)
        model.meetingWasDetected(zoomCall())

        XCTAssertEqual(model.presentation, .hidden)
    }

    func testTheTransportStaysAfterTheCallItselfHasEnded() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        // Hanging up does not save the recording; somebody still has to stop it,
        // and the chip is where they were last told they could.
        model.meetingWasDetected(nil)

        guard case .session = model.presentation else { return XCTFail("expected the transport") }
    }

    func testAnOptedInMeetingRecordingStopsWhenTheCallEnds() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = MeetingChipModel(
            coordinator: coordinator,
            shouldStopWhenMeetingEnds: { true }
        )
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        model.meetingWasDetected(nil)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertEqual(coordinator.performedCommands.filter { $0 == .stop }, [.stop])
        XCTAssertEqual(model.presentation, .hidden)
    }

    func testAutomaticStopDoesNotTouchARecordingStartedFromTheMenu() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = MeetingChipModel(
            coordinator: coordinator,
            shouldStopWhenMeetingEnds: { true }
        )
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()
        model.meetingWasDetected(zoomCall())

        model.meetingWasDetected(nil)
        await coordinator.waitUntilIdle()

        XCTAssertTrue(coordinator.snapshot.state.isRecording)
        XCTAssertFalse(coordinator.performedCommands.contains(.stop))
    }

    func testAReplacementCallStopsTheRecordingForThePreviousCall() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = MeetingChipModel(
            coordinator: coordinator,
            shouldStopWhenMeetingEnds: { true }
        )
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        model.meetingWasDetected(browserCall(domain: "meet.google.com", at: Date(timeIntervalSince1970: 2_000)))
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state, .idle)
        XCTAssertEqual(coordinator.performedCommands.filter { $0 == .stop }, [.stop])
    }

    // MARK: The transport

    func testTheHoldButtonPausesAndThenResumes() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        model.toggleHold()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.snapshot.state.isPaused)
        guard case .session(let paused) = model.presentation else { return XCTFail("expected the transport") }
        XCTAssertTrue(paused.isPaused)

        model.toggleHold()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(coordinator.snapshot.state.isRecording)
    }

    func testStoppingFromTheChipEndsTheRecordingAndTheChip() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        model.stop()
        await coordinator.waitUntilIdle()

        XCTAssertEqual(coordinator.snapshot.state, .idle)
        // The call may still be running — a person can stop recording and keep
        // talking — but they have answered the question, so it is not asked again.
        XCTAssertEqual(model.presentation, .hidden)
    }

    func testTheClockKeepsRunningWhilePaused() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        var now = start
        let model = makeModel(coordinator, now: { now })
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()
        model.toggleHold()
        await coordinator.waitUntilIdle()

        now = start.addingTimeInterval(2)
        model.refreshPresentation()

        // A paused span is reconstructed as silence, so this is the length of the
        // file being produced rather than only the audible part of it.
        XCTAssertEqual(model.presentation, .session(.init(
            elapsedText: "00:02",
            isPaused: true,
            isHoldEnabled: true,
            isStopEnabled: true
        )))
    }

    // MARK: Staying out of the way

    func testARecordingStartedFromTheMenuGetsNoChip() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)

        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        // Nothing was noticed and nothing was offered, so a floating transport
        // over every window is a surprise rather than a convenience.
        XCTAssertEqual(model.presentation, .hidden)
    }

    func testACallNoticedDuringARecordingIsNotOfferedAgain() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        model.meetingWasDetected(zoomCall())

        // The recording that is running is the answer to "record this meeting?",
        // so the chip becomes its transport rather than asking.
        guard case .session = model.presentation else { return XCTFail("expected the transport") }
    }

    func testTheChipIsReleasedWhenTheRecordingItStartedIsFinished() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()
        model.stop()
        model.meetingWasDetected(nil)
        await coordinator.waitUntilIdle()

        // A second recording, from the menu this time, must not inherit the chip.
        coordinator.submit(.start)
        await coordinator.waitUntilIdle()

        XCTAssertEqual(model.presentation, .hidden)
    }

    func testTheChipHasNoTimestampControlOfItsOwn() async {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        model.meetingWasDetected(zoomCall())
        model.record()
        await coordinator.waitUntilIdle()

        // The clock on the chip is a label. Copy Timestamp is a menu command
        // with a global shortcut, which is what a person reaches for mid-call
        // anyway — the chip is gone seconds after the recording starts.
        XCTAssertTrue(coordinator.copiedTimestamps.isEmpty)
        XCTAssertFalse(coordinator.performedCommands.contains(.copyTimestamp))
    }

    // MARK: The panel

    func testPanelLayoutSettlesAcrossRecordingTransitions() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("No display attached") }
        let start = Date(timeIntervalSince1970: 1_000)
        var now = start
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot(), now: { start })
        let model = makeModel(coordinator, now: { now })
        let anchor = NSRect(x: screen.frame.midX, y: screen.frame.maxY - 22, width: 24, height: 22)
        let controller = MeetingChipController(model: model, anchor: { anchor })
        defer { controller.window.orderOut(nil) }

        func assertSettled(file: StaticString = #filePath, line: UInt = #line) {
            controller.window.layoutIfNeeded()
            controller.window.displayIfNeeded()
            let frame = controller.window.frame
            XCTAssertGreaterThan(frame.width, 100, file: file, line: line)
            XCTAssertLessThan(frame.width, screen.frame.width, file: file, line: line)
            XCTAssertEqual(frame.midX, anchor.midX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.maxY, anchor.minY + 4, accuracy: 1, file: file, line: line)
            for _ in 0..<10 {
                controller.window.contentView?.needsLayout = true
                controller.window.layoutIfNeeded()
                controller.window.displayIfNeeded()
                XCTAssertEqual(controller.window.frame, frame, file: file, line: line)
            }
        }

        model.meetingWasDetected(zoomCall(calendarTitle: "Weekly planning with the entire product team"))
        assertSettled()
        model.record()
        await coordinator.waitUntilIdle()
        assertSettled()
        model.toggleHold()
        await coordinator.waitUntilIdle()
        assertSettled()
        model.toggleHold()
        await coordinator.waitUntilIdle()
        now = start.addingTimeInterval(2)
        model.refreshPresentation()
        assertSettled()
        now = start.addingTimeInterval(MeetingChipPresentation.sessionVisibleDuration)
        model.refreshPresentation()
        XCTAssertFalse(controller.window.isVisible)
        coordinator.submit(.stop)
        await coordinator.waitUntilIdle()
        model.meetingWasDetected(zoomCall(at: start.addingTimeInterval(100)))
        XCTAssertTrue(controller.window.isVisible)
        assertSettled()
    }

    func testThePanelIsOrderedInAndOutWithTheChip() {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        let anchor = NSRect(x: 900, y: 1_000, width: 24, height: 22)
        let controller = MeetingChipController(model: model, anchor: { anchor })

        XCTAssertFalse(controller.window.isVisible)

        model.meetingWasDetected(zoomCall())
        XCTAssertTrue(controller.window.isVisible)

        model.meetingWasDetected(nil)
        XCTAssertFalse(controller.window.isVisible)
    }

    func testThePanelHangsUnderTheStatusItemWithoutTakingFocus() throws {
        let coordinator = MockRecordingCoordinator(snapshot: readySnapshot())
        let model = makeModel(coordinator)
        guard let screen = NSScreen.main else {
            throw XCTSkip("No display attached; there is nothing to position against.")
        }
        let anchor = NSRect(x: screen.frame.midX, y: screen.frame.maxY - 22, width: 24, height: 22)
        let controller = MeetingChipController(model: model, anchor: { anchor })

        model.meetingWasDetected(zoomCall())

        let frame = controller.window.frame
        XCTAssertEqual(frame.midX, anchor.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(frame.maxY, anchor.minY + 4)
        // It arrives while the person is in a call: taking the keyboard away from
        // the meeting would be worse than not appearing at all.
        XCTAssertFalse(controller.window.canBecomeKey && controller.window.isKeyWindow)
        XCTAssertTrue(controller.window.isFloatingPanel)
    }

    // MARK: Helpers

    private func makeModel(
        _ coordinator: MockRecordingCoordinator,
        now: @escaping @MainActor () -> Date = { Date() }
    ) -> MeetingChipModel {
        MeetingChipModel(coordinator: coordinator, now: now)
    }

    private func readySnapshot() -> RecorderSnapshot {
        RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: URL(fileURLWithPath: "/tmp/scribe", isDirectory: true))
    }

    private func zoomCall(at date: Date = Date(timeIntervalSince1970: 1_000), calendarTitle: String? = nil) -> DetectedMeeting {
        DetectedMeeting(
            application: MeetingApplication.catalog.first { $0.id == "zoom" }!,
            bundleIdentifier: "us.zoom.xos",
            processIdentifier: 501,
            domain: nil,
            detectedAt: date,
            calendarTitle: calendarTitle
        )
    }

    private func browserCall(domain: String, at date: Date = Date(timeIntervalSince1970: 1_000)) -> DetectedMeeting {
        DetectedMeeting(
            application: MeetingApplication.catalog.first { $0.id == "arc" }!,
            bundleIdentifier: "company.thebrowser.Browser",
            processIdentifier: 502,
            domain: domain,
            detectedAt: date
        )
    }
}
