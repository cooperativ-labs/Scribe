import ScribeUI
import XCTest

final class FirstRunSetupTests: XCTestCase {
    func testWindowShowsOnceEvenWhenEverythingIsGranted() {
        XCTAssertTrue(FirstRunSetup.shouldPresent(recordingReady: true, dictationReady: true, setupCompleted: false))
    }

    func testWindowStaysHiddenAfterSetupWhenReady() {
        XCTAssertFalse(FirstRunSetup.shouldPresent(recordingReady: true, dictationReady: true, setupCompleted: true))
    }

    func testWindowReturnsWhenAPermissionIsMissing() {
        XCTAssertTrue(FirstRunSetup.shouldPresent(recordingReady: false, dictationReady: true, setupCompleted: true))
        XCTAssertTrue(FirstRunSetup.shouldPresent(recordingReady: true, dictationReady: false, setupCompleted: true))
    }
}
