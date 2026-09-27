import XCTest
import AppKit
import Platform
@testable import Dictation

/// Synthetic modifier sequences across the two modes. Device flags from the SDK:
/// right Command 0x10, right Shift 0x04, left Control 0x01, right Control 0x2000,
/// left Option 0x20.
final class DictationTriggerRouterTests: XCTestCase {
    private let rightCommand = NSEvent.ModifierFlags.command.union(.init(rawValue: 0x10))
    private let rightShift = NSEvent.ModifierFlags.shift.union(.init(rawValue: 0x04))
    private let leftControl = NSEvent.ModifierFlags.control.union(.init(rawValue: 0x01))
    private let leftOption = NSEvent.ModifierFlags.option.union(.init(rawValue: 0x20))

    private func router(
        dictation: DictationActivationKey? = .rightCommand,
        assistant: DictationActivationKey? = .rightShift
    ) -> DictationTriggerRouter {
        var router = DictationTriggerRouter()
        var keys: [DictationIntent: DictationActivationKey] = [:]
        keys[.dictation] = dictation
        keys[.assistant] = assistant
        XCTAssertEqual(router.setKeys(keys), [])
        return router
    }

    private func flags(
        _ router: inout DictationTriggerRouter,
        _ time: Double,
        code: UInt16,
        _ flags: NSEvent.ModifierFlags
    ) -> [DictationTriggerEvent] {
        router.flagsChanged(keyCode: code, flags: flags, time: time).events
    }

    func testEachModeHoldsOnItsOwnKey() {
        var router = router()
        let press = router.flagsChanged(keyCode: 60, flags: rightShift, time: 1)
        XCTAssertEqual(press.events, [.listeningStarted(.hold, .assistant)])
        XCTAssertEqual(press.observed, [.assistant])
        XCTAssertEqual(flags(&router, 1.5, code: 60, []), [.listeningEnded(.assistant)])

        XCTAssertEqual(flags(&router, 2, code: 54, rightCommand), [.listeningStarted(.hold, .dictation)])
        XCTAssertEqual(flags(&router, 2.5, code: 54, []), [.listeningEnded(.dictation)])
    }

    func testDoubleTapTogglesTheAssistantAndLeavesDictationAlone() {
        var router = router()
        _ = flags(&router, 1, code: 60, rightShift)
        XCTAssertEqual(flags(&router, 1.1, code: 60, []), [.cancelled(.shortTap, .assistant)])
        XCTAssertEqual(flags(&router, 1.2, code: 60, rightShift), [.listeningStarted(.doubleTap, .assistant)])
        XCTAssertEqual(flags(&router, 1.3, code: 60, []), [])
        XCTAssertTrue(router.isToggleActive)
        XCTAssertEqual(flags(&router, 2, code: 60, rightShift), [])
        XCTAssertEqual(flags(&router, 2.1, code: 60, []), [.listeningEnded(.assistant)])
        XCTAssertFalse(router.isToggleActive)
    }

    func testAssistantKeyCancelsListeningDictationAndTheReverse() {
        var router = router()
        _ = flags(&router, 1, code: 54, rightCommand)
        XCTAssertEqual(
            flags(&router, 1.2, code: 60, rightCommand.union(rightShift)),
            [.listeningStarted(.hold, .assistant), .cancelled(.chord, .dictation)]
        )
        // The cancelled key's release must not end or restart anything.
        XCTAssertEqual(flags(&router, 1.5, code: 54, rightShift), [])
        XCTAssertEqual(flags(&router, 2, code: 60, []), [.listeningEnded(.assistant)])

        _ = flags(&router, 3, code: 60, rightShift)
        XCTAssertEqual(
            flags(&router, 3.2, code: 54, rightShift.union(rightCommand)),
            [.listeningStarted(.hold, .dictation), .cancelled(.chord, .assistant)]
        )
        XCTAssertEqual(flags(&router, 3.5, code: 60, rightCommand), [])
        XCTAssertEqual(flags(&router, 4, code: 54, []), [.listeningEnded(.dictation)])
    }

    func testChordStartsWhenFnIsPressedFirst() {
        var router = router(assistant: .functionControl)
        let fn = router.flagsChanged(keyCode: 63, flags: .function, time: 1)
        XCTAssertEqual(fn.events, [])
        XCTAssertEqual(fn.observed, [])
        let both = router.flagsChanged(keyCode: 59, flags: leftControl.union(.function), time: 1.1)
        XCTAssertEqual(both.events, [.listeningStarted(.hold, .assistant)])
        XCTAssertEqual(both.observed, [.assistant])
        // The hold threshold runs from the moment both are down; releasing
        // either key ends it.
        XCTAssertEqual(flags(&router, 1.6, code: 63, leftControl), [.listeningEnded(.assistant)])
        XCTAssertEqual(flags(&router, 1.7, code: 59, []), [])
    }

    func testChordStartsWhenControlIsPressedFirst() {
        var router = router(assistant: .functionControl)
        XCTAssertEqual(flags(&router, 1, code: 62, .control.union(.init(rawValue: 0x2000))), [])
        XCTAssertEqual(
            flags(&router, 1.1, code: 63, NSEvent.ModifierFlags([.control, .function]).union(.init(rawValue: 0x2000))),
            [.listeningStarted(.hold, .assistant)]
        )
        XCTAssertEqual(flags(&router, 1.2, code: 62, .function), [.cancelled(.shortTap, .assistant)])
        XCTAssertEqual(flags(&router, 1.3, code: 63, []), [])
    }

    func testChordOverFnDictationCancelsTheDictation() {
        var router = router(dictation: .function, assistant: .functionControl)
        XCTAssertEqual(flags(&router, 1, code: 63, .function), [.listeningStarted(.hold, .dictation)])
        XCTAssertEqual(
            flags(&router, 1.1, code: 59, leftControl.union(.function)),
            [.listeningStarted(.hold, .assistant), .cancelled(.chord, .dictation)]
        )
        XCTAssertEqual(flags(&router, 1.6, code: 59, .function), [.listeningEnded(.assistant)])
        XCTAssertEqual(flags(&router, 1.7, code: 63, []), [])
        // Fn alone still dictates afterwards.
        XCTAssertEqual(flags(&router, 2, code: 63, .function), [.listeningStarted(.hold, .dictation)])
    }

    func testEscapeCancelsADoubleTapSessionAndAHold() {
        var router = router()
        _ = flags(&router, 1, code: 60, rightShift)
        _ = flags(&router, 1.1, code: 60, [])
        _ = flags(&router, 1.2, code: 60, rightShift)
        _ = flags(&router, 1.3, code: 60, [])
        XCTAssertEqual(router.keyDown(keyCode: 53, time: 2), [.cancelled(.stopped, .assistant)])
        XCTAssertFalse(router.isToggleActive)

        _ = flags(&router, 3, code: 54, rightCommand)
        XCTAssertEqual(router.keyDown(keyCode: 53, time: 3.2), [.cancelled(.chord, .dictation)])
        XCTAssertEqual(flags(&router, 3.5, code: 54, []), [])
    }

    func testTypingWithLeftOptionIsACancelledChord() {
        var router = router(assistant: .leftOption)
        XCTAssertEqual(flags(&router, 1, code: 58, leftOption), [.listeningStarted(.hold, .assistant)])
        XCTAssertEqual(router.keyDown(keyCode: 14, time: 1.05), [.cancelled(.chord, .assistant)])
        XCTAssertEqual(flags(&router, 1.1, code: 58, []), [])
    }

    func testIndicatorStopAndCancelEndOnlyTheToggledMode() {
        var router = router()
        _ = flags(&router, 1, code: 54, rightCommand)
        _ = flags(&router, 1.1, code: 54, [])
        _ = flags(&router, 1.2, code: 54, rightCommand)
        _ = flags(&router, 1.3, code: 54, [])
        XCTAssertEqual(router.stopToggle(), [.listeningEnded(.dictation)])
        XCTAssertEqual(router.cancelToggle(), [])
    }

    func testSecureInputBlocksBothKeys() {
        var router = router()
        let result = router.flagsChanged(keyCode: 60, flags: rightShift, time: 1, secureInput: true)
        XCTAssertEqual(result.events, [.secureInputBlocked])
    }

    func testRemovingOrMovingAModeCancelsOnlyThatMode() {
        var router = router()
        _ = flags(&router, 1, code: 60, rightShift)
        XCTAssertEqual(router.setKeys([.dictation: .rightCommand]), [.cancelled(.stopped, .assistant)])
        XCTAssertEqual(router.activationKeys, [.dictation: .rightCommand])
        XCTAssertEqual(flags(&router, 2, code: 60, rightShift), [])

        _ = flags(&router, 3, code: 54, rightCommand)
        XCTAssertEqual(
            router.setKeys([.dictation: .rightOption, .assistant: .rightShift]),
            [.cancelled(.stopped, .dictation)]
        )
        XCTAssertEqual(router.activationKeys, [.dictation: .rightOption, .assistant: .rightShift])
    }

    func testTimingAppliesToEveryMode() {
        var router = router()
        router.holdThreshold = 0.5
        _ = flags(&router, 1, code: 60, rightShift)
        XCTAssertEqual(flags(&router, 1.4, code: 60, []), [.cancelled(.shortTap, .assistant)])
        router.maximumDuration = 5
        _ = flags(&router, 10, code: 54, rightCommand)
        XCTAssertEqual(router.advance(to: 16), [.cancelled(.maximumDuration, .dictation)])
    }
}
