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
    func testDropsNoise() {
        XCTAssertNil(DictationTextShaper.shape(" .!? ", preceding: nil, fieldIsEmpty: true, options: .init()))
        XCTAssertNil(DictationTextShaper.shape("a", preceding: nil, fieldIsEmpty: true, options: .init()))
    }
}

private final class FakeAX: FocusedFieldAXClient, @unchecked Sendable {
    let element = AXUIElementCreateSystemWide()
    let targetPID: pid_t = 1234
    var value = "before"
    var range = CFRange(location: 6, length: 0)
    var directWorks = false
    var textRole = true
    var electron = false
    var manualAccessibilityRequests = 0
    func focusedElement(frontmostPID: pid_t) -> AXUIElement? { frontmostPID == targetPID ? element : nil }
    func pid(of element: AXUIElement) -> pid_t? { targetPID }
    func string(_ attribute: String, of element: AXUIElement) -> String? {
        attribute == kAXRoleAttribute as String ? (textRole ? "AXTextArea" : "AXButton") : nil
    }
    func valueLength(of element: AXUIElement) -> Int? { value.utf16.count }
    func selectedRange(of element: AXUIElement) -> CFRange? { range }
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool { true }
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        if directWorks { value += text; range.location += text.utf16.count }
        return true
    }
    func precedingCharacter(of element: AXUIElement, range: CFRange) -> String? { " " }
    func frame(of element: AXUIElement) -> CGRect? { nil }
    func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect? { nil }
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
    @MainActor func testManualAccessibilityRequestedOncePerProcess() async {
        let ax = FakeAX()
        ax.textRole = false
        let locator = FocusedFieldLocator(client: ax)
        _ = await locator.locate(frontmostPID: ax.targetPID, screenTop: 100, screens: [])
        _ = await locator.locate(frontmostPID: ax.targetPID, screenTop: 100, screens: [])
        XCTAssertEqual(ax.manualAccessibilityRequests, 1)
    }
}
