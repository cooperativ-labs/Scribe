import AppKit
import XCTest
@testable import ScribeUI

@MainActor
final class TransientHintControllerTests: XCTestCase {
    func testAHintAppearsWithoutTakingFocusAndGoesAwayByItself() async throws {
        _ = NSApplication.shared
        let hint = TransientHintController(anchor: { NSRect(x: 600, y: 900, width: 24, height: 22) }, duration: .milliseconds(100))

        hint.show("Meeting Notes opens while a recording is in progress.")

        XCTAssertTrue(hint.window.isVisible)
        XCTAssertEqual(hint.message, "Meeting Notes opens while a recording is in progress.")
        XCTAssertFalse(hint.window.canBecomeKey, "it never takes the keyboard from the app in front")
        XCTAssertTrue(hint.window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(hint.window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(hint.window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(hint.window.ignoresMouseEvents)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(hint.window.isVisible)
        XCTAssertNil(hint.message)
    }

    func testShowingAgainReplacesTheHintAndRestartsItsTime() async throws {
        let hint = TransientHintController(anchor: { nil }, duration: .milliseconds(300))
        hint.show("First")
        try await Task.sleep(for: .milliseconds(200))
        hint.show("Second")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hint.window.isVisible, "the second hint gets its own time")
        XCTAssertEqual(hint.message, "Second")
        hint.hide()
        XCTAssertFalse(hint.window.isVisible)
    }
}
