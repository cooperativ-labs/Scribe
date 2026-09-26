import XCTest
import AppKit
import Platform
@testable import Dictation

final class DictationTriggerStateTests: XCTestCase {
    func testEverySelectedKeySupportsHoldAndToggle() {
        for activationKey in DictationActivationKey.allCases {
            var state = DictationTriggerState(activationKey: activationKey)
            let code = activationKey.keyCode
            XCTAssertEqual(state.handle(key(1, true, code: code)), [.listeningStarted(.hold)])
            XCTAssertEqual(state.handle(key(1.4, false, code: code)), [.listeningEnded])
            _ = state.handle(key(2, true, code: code))
            _ = state.handle(key(2.1, false, code: code))
            XCTAssertEqual(state.handle(key(2.2, true, code: code)), [.listeningStarted(.doubleTap)])
            XCTAssertEqual(state.handle(key(2.3, false, code: code)), [])
            _ = state.handle(key(3, true, code: code))
            XCTAssertEqual(state.handle(key(3.1, false, code: code)), [.listeningEnded])
        }
    }

    func testSelectedKeysIgnoreOtherTriggersAndBlockChordsAndSecureInput() {
        for activationKey in DictationActivationKey.allCases {
            var state = DictationTriggerState(activationKey: activationKey)
            for other in DictationActivationKey.allCases where other != activationKey {
                XCTAssertEqual(state.handle(key(0, true, code: other.keyCode)), [])
                XCTAssertEqual(state.handle(key(0.1, false, code: other.keyCode)), [])
            }
            _ = state.handle(key(1, true, code: activationKey.keyCode))
            XCTAssertEqual(state.handle(key(1.1, true, code: 8)), [.cancelled(.chord)])
            XCTAssertEqual(state.handle(key(1.5, false, code: activationKey.keyCode)), [])
            XCTAssertEqual(state.handle(key(2, true, code: activationKey.keyCode), secureInput: true), [.secureInputBlocked])
        }
    }

    func testSwitchingKeysCancelsCaptureAndClearsPendingDoubleTap() {
        var state = DictationTriggerState()
        _ = state.handle(key(1, true))
        XCTAssertEqual(state.setActivationKey(.rightShift), [.cancelled(.stopped)])
        XCTAssertEqual(state.handle(key(1.4, false)), [])
        // A release without a press must not start a new capture.
        XCTAssertEqual(state.handle(key(1.5, false, code: 60)), [])
        XCTAssertEqual(state.handle(key(2, true, code: 60)), [.listeningStarted(.hold)])
        _ = state.handle(key(2.1, false, code: 60))
        _ = state.setActivationKey(.function)
        XCTAssertEqual(state.handle(key(2.2, true, code: 63)), [.listeningStarted(.hold)])
    }

    func testRightModifierReleaseWhileLeftModifierRemainsHeld() {
        // SDK device flags: left/right Command = 0x08/0x10,
        // left/right Shift = 0x02/0x04.
        let bothCommand = NSEvent.ModifierFlags.command.union(.init(rawValue: 0x18))
        let leftCommand = NSEvent.ModifierFlags.command.union(.init(rawValue: 0x08))
        XCTAssertTrue(DictationActivationKey.rightCommand.isPressed(in: bothCommand))
        XCTAssertFalse(DictationActivationKey.rightCommand.isPressed(in: leftCommand))
        let bothShift = NSEvent.ModifierFlags.shift.union(.init(rawValue: 0x06))
        let leftShift = NSEvent.ModifierFlags.shift.union(.init(rawValue: 0x02))
        XCTAssertTrue(DictationActivationKey.rightShift.isPressed(in: bothShift))
        XCTAssertFalse(DictationActivationKey.rightShift.isPressed(in: leftShift))
        XCTAssertTrue(DictationActivationKey.function.isPressed(in: .function))
        XCTAssertFalse(DictationActivationKey.function.isPressed(in: []))
    }

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
