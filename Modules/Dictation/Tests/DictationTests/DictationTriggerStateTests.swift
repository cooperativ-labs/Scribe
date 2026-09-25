import XCTest
@testable import Dictation

final class DictationTriggerStateTests: XCTestCase {
    private func key(_ time: Double, _ down: Bool, code: UInt16 = 54) -> DictationKeyEvent {
        DictationKeyEvent(time: time, keyCode: code, isDown: down)
    }

    func testHoldStartsImmediatelyAndEndsOnRelease() {
        var state = DictationTriggerState()
        XCTAssertEqual(state.handle(key(1, true)), [.listeningStarted(.hold)])
        XCTAssertEqual(state.handle(key(1.4, false)), [.listeningEnded])
    }

    func testShortTapIsDiscarded() {
        var state = DictationTriggerState()
        XCTAssertEqual(state.handle(key(1, true)), [.listeningStarted(.hold)])
        XCTAssertEqual(state.handle(key(1.1, false)), [.cancelled(.shortTap)])
    }

    func testDoubleTapOpensAndNextTapCloses() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        _ = state.handle(key(1.1, false))
        XCTAssertEqual(state.handle(key(1.3, true)), [.listeningStarted(.doubleTap)])
        XCTAssertEqual(state.handle(key(1.35, false)), [])
        XCTAssertEqual(state.handle(key(2, true)), [])
        XCTAssertEqual(state.handle(key(2.1, false)), [.listeningEnded])
    }

    func testChordCancelsAndReleaseDoesNotRestart() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        XCTAssertEqual(state.handle(key(1.2, true, code: 8)), [.cancelled(.chord)])
        XCTAssertEqual(state.handle(key(1.4, false)), [])
    }

    func testLeftCommandDoesNotChangeRightCommandState() {
        var state = DictationTriggerState()
        XCTAssertEqual(state.handle(key(0, true, code: 55)), [])
        XCTAssertEqual(state.handle(key(1, true)), [.listeningStarted(.hold)])
        XCTAssertEqual(state.handle(key(1.4, false)), [.listeningEnded])
        XCTAssertEqual(state.handle(key(1.5, false, code: 55)), [])
    }

    func testMaximumDurationCancels() {
        var state = DictationTriggerState()
        state.maximumDuration = 5
        _ = state.handle(key(1, true))
        XCTAssertEqual(state.advance(to: 6), [.cancelled(.maximumDuration)])
    }

    func testToggleCanOpenAgainAfterClosing() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        _ = state.handle(key(1.1, false))
        _ = state.handle(key(1.2, true))
        _ = state.handle(key(1.3, false))
        _ = state.handle(key(2, true))
        XCTAssertEqual(state.handle(key(2.1, false)), [.listeningEnded])
        _ = state.handle(key(3, true))
        _ = state.handle(key(3.1, false))
        XCTAssertEqual(state.handle(key(3.2, true)), [.listeningStarted(.doubleTap)])
        XCTAssertEqual(state.handle(key(3.3, false)), [])
    }

    func testSecureInputBlocksTrigger() {
        var state = DictationTriggerState()
        XCTAssertEqual(state.handle(key(1, true), secureInput: true), [.secureInputBlocked])
    }

    func testPanelStopFinishesToggleAndNextPressStartsCleanly() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        _ = state.handle(key(1.1, false))
        _ = state.handle(key(1.2, true))
        _ = state.handle(key(1.3, false))
        XCTAssertTrue(state.isToggleActive)
        XCTAssertEqual(state.finishToggle(), [.listeningEnded])
        XCTAssertFalse(state.isToggleActive)
        XCTAssertEqual(state.handle(key(2, true)), [.listeningStarted(.hold)])
    }

    func testPanelCancelDiscardsToggle() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        _ = state.handle(key(1.1, false))
        _ = state.handle(key(1.2, true))
        XCTAssertEqual(state.cancel(.stopped), [.cancelled(.stopped)])
        XCTAssertFalse(state.isToggleActive)
    }
}
