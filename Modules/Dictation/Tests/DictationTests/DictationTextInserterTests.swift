import ApplicationServices
import AppKit
import Platform
import XCTest
@testable import Dictation

final class DictationTextShaperTests: XCTestCase {
    func testSpacingAndCapitalization() {
        let options = DictationTextOptions(leadingSpace: true, trailingSpace: true)
        XCTAssertEqual(DictationTextShaper.shape("  hello world  ", preceding: "Hi.", fieldIsEmpty: false, options: options), " Hello world ")
        XCTAssertEqual(DictationTextShaper.shape("hello world", preceding: "\n", fieldIsEmpty: false, options: options), "hello world ")
        XCTAssertEqual(DictationTextShaper.shape("hello world", preceding: nil, fieldIsEmpty: true, options: options), "hello world ")
        XCTAssertEqual(DictationTextShaper.shape("hello world", preceding: nil, fieldIsEmpty: false, options: options), " hello world ")
    }
    func testGeneratedTextKeepsParagraphsAndCapitalisation() {
        let options = DictationTextOptions(leadingSpace: true, trailingSpace: true)
        let reply = "\n  Hi Sam,\n\nThursday works. friday does not.\n\nBest,\nJake \n"
        XCTAssertEqual(DictationTextShaper.shapeGenerated(reply, preceding: "x", options: options),
                       "Hi Sam,\n\nThursday works. friday does not.\n\nBest,\nJake")
        XCTAssertEqual(DictationTextShaper.shapeGenerated(" sounds good ", preceding: "Yes,", options: options), " sounds good")
        XCTAssertEqual(DictationTextShaper.shapeGenerated("sounds good", preceding: " ", options: options), "sounds good")
        XCTAssertEqual(DictationTextShaper.shapeGenerated("sounds good", preceding: nil, options: options), "sounds good")
        XCTAssertEqual(DictationTextShaper.shapeGenerated("sounds good", preceding: "x",
                                                         options: DictationTextOptions(leadingSpace: false)), "sounds good")
        XCTAssertEqual(DictationTextShaper.shapeGenerated("a", preceding: nil, options: options), "a")
        XCTAssertNil(DictationTextShaper.shapeGenerated(" \n ", preceding: nil, options: options))
    }
    func testDropsNoise() {
        XCTAssertNil(DictationTextShaper.shape(" .!? ", preceding: nil, fieldIsEmpty: true, options: .init()))
        XCTAssertNil(DictationTextShaper.shape("a", preceding: nil, fieldIsEmpty: true, options: .init()))
    }
}

private final class FakeAX: FocusedFieldAXClient, @unchecked Sendable {
    let element = AXUIElementCreateSystemWide()
    let targetPID: pid_t = 1234
    var elementPID: pid_t = 1234
    var value = "before"
    var range = CFRange(location: 6, length: 0)
    var caret = CGRect(x: 40, y: 20, width: 2, height: 16)
    var preceding: String? = " "
    var directWorks = false
    var textRole = true
    var electron = false
    var manualAccessibilityRequests = 0
    func focusedElement(frontmostPID: pid_t) -> AXUIElement? { frontmostPID == targetPID ? element : nil }
    func pid(of element: AXUIElement) -> pid_t? { elementPID }
    func string(_ attribute: String, of element: AXUIElement) -> String? {
        attribute == kAXRoleAttribute as String ? (textRole ? "AXTextArea" : "AXButton") : nil
    }
    func valueLength(of element: AXUIElement) -> Int? { value.utf16.count }
    func selectedRange(of element: AXUIElement) -> CFRange? { range }
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool { true }
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        if directWorks {
            value = (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
            range = CFRange(location: range.location + text.utf16.count, length: 0)
        }
        return true
    }
    func precedingCharacter(of element: AXUIElement, range: CFRange) -> String? { preceding }
    func frame(of element: AXUIElement) -> CGRect? { nil }
    func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect? { caret }
    func window(of element: AXUIElement) -> AXUIElement? { nil }
    func enableManualAccessibility(pid: pid_t) -> Bool {
        manualAccessibilityRequests += 1
        if electron { textRole = true }
        return electron
    }
}

@MainActor private final class FakePaste: DictationPasteClient {
    var pasted: String?
    var copied: String?
    func copyOnly(_ text: String) { copied = text }
    func insertAndReport(_ text: String, restoreClipboard: Bool) async -> PasteInsertionOutcome {
        pasted = text
        return .posted
    }
}

final class DictationTextInserterTests: XCTestCase {
    @MainActor func testDirectWriteAndNoOpPasteFallback() async {
        let ax = FakeAX()
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        ax.directWorks = true
        let first = await inserter.insertDictation("hello", frontmostPID: ax.targetPID, screenTop: 100,
                                                  screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(first, .accessibility)
        XCTAssertNil(paste.pasted)
        ax.directWorks = false
        let second = await inserter.insertDictation("again", frontmostPID: ax.targetPID, screenTop: 100,
                                                   screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(second, .pasted)
        XCTAssertEqual(paste.pasted, "again")
    }
    @MainActor func testUnknownRoleCopiesWithoutPosting() async {
        let ax = FakeAX()
        ax.textRole = false
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertDictation("hello", frontmostPID: ax.targetPID, screenTop: 100,
                                                    screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(paste.copied, " hello")
        XCTAssertNil(paste.pasted)
    }
    @MainActor func testElectronTreeIsEnabledBeforeInsertion() async {
        let ax = FakeAX()
        ax.textRole = false
        ax.electron = true
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertDictation("hello", frontmostPID: ax.targetPID, screenTop: 100,
                                                    screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(paste.pasted, "hello")
        XCTAssertNil(paste.copied)
        XCTAssertEqual(ax.manualAccessibilityRequests, 1)
    }
    @MainActor func testFocusedFieldHostedByApplicationHelperStillAcceptsInsertion() async {
        let ax = FakeAX()
        ax.elementPID = 5678
        let paste = FakePaste()
        let locator = FocusedFieldLocator(client: ax)
        let snapshot = await locator.locate(frontmostPID: ax.targetPID, screenTop: 100,
                                            screens: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        XCTAssertNotNil(snapshot)
        if let snapshot {
            let stillFocused = await locator.stillFocused(snapshot, frontmostPID: ax.targetPID)
            XCTAssertTrue(stillFocused)
            XCTAssertEqual(snapshot.caretRect, CGRect(x: 40, y: 64, width: 2, height: 16))
        }
        let inserter = DictationTextInserter(locator: locator, paste: paste)
        let outcome = await inserter.insertDictation("hello", frontmostPID: ax.targetPID, screenTop: 100,
                                                    screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(paste.pasted, "hello")
    }
    @MainActor func testManualAccessibilityRequestedOncePerProcess() async {
        let ax = FakeAX()
        ax.textRole = false
        let locator = FocusedFieldLocator(client: ax)
        _ = await locator.locate(frontmostPID: ax.targetPID, screenTop: 100, screens: [])
        _ = await locator.locate(frontmostPID: ax.targetPID, screenTop: 100, screens: [])
        XCTAssertEqual(ax.manualAccessibilityRequests, 1)
    }
}

final class DictationGeneratedInsertionTests: XCTestCase {
    @MainActor func testReplacesTheSelectionThroughAccessibility() async {
        let ax = FakeAX()
        ax.value = "Please make this shorter, thanks"
        ax.range = CFRange(location: 7, length: 17)
        ax.preceding = " "
        ax.directWorks = true
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertGenerated("  shorten this\n", frontmostPID: ax.targetPID, screenTop: 100,
                                                     screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .accessibility)
        XCTAssertEqual(ax.value, "Please shorten this, thanks")
        XCTAssertNil(paste.pasted)
    }
    @MainActor func testSilentAXFailureOverASelectionFallsBackToPaste() async {
        let ax = FakeAX()
        ax.value = "Hello world"
        ax.range = CFRange(location: 6, length: 5)
        ax.directWorks = false
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertGenerated("there", frontmostPID: ax.targetPID, screenTop: 100,
                                                     screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(paste.pasted, "there")
    }
    @MainActor func testMultiParagraphAnswerPastesVerbatimAfterText() async {
        let ax = FakeAX()
        ax.preceding = "e"
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertGenerated("Hi Sam,\n\nThursday works.", frontmostPID: ax.targetPID,
                                                     screenTop: 100, screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(paste.pasted, "Hi Sam,\n\nThursday works.")
    }
    @MainActor func testSingleLineGetsALeadingSpaceAfterText() async {
        let ax = FakeAX()
        ax.preceding = "e"
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        _ = await inserter.insertGenerated("Thursday works.", frontmostPID: ax.targetPID,
                                           screenTop: 100, screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(paste.pasted, " Thursday works.")
    }
    @MainActor func testCopyOnlyNeverTouchesTheField() async {
        let ax = FakeAX()
        ax.directWorks = true
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertGenerated(" Reply text \n", copyOnly: true, frontmostPID: ax.targetPID,
                                                     screenTop: 100, screens: [], currentPID: { ax.targetPID })
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(paste.copied, "Reply text")
        XCTAssertEqual(ax.value, "before")
        XCTAssertNil(paste.pasted)
    }
    @MainActor func testAnswerIsCopiedWhenFocusMoved() async {
        let ax = FakeAX()
        let paste = FakePaste()
        let inserter = DictationTextInserter(locator: FocusedFieldLocator(client: ax), paste: paste)
        let outcome = await inserter.insertGenerated("Reply text", frontmostPID: ax.targetPID,
                                                     screenTop: 100, screens: [], currentPID: { 999 })
        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(paste.copied, "Reply text")
        XCTAssertNil(paste.pasted)
    }
}
