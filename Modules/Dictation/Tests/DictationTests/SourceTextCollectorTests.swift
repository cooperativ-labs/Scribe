import ApplicationServices
import Assist
import XCTest
@testable import Dictation

/// A fake Accessibility tree. Each element is an application element with its
/// own made-up pid, which gives it a distinct `CFEqual` identity.
private final class TreeAX: FocusedFieldAXClient, @unchecked Sendable {
    let appPID: pid_t = 4321
    private var nextID: pid_t = 50_000
    var nodes: [pid_t: AXWalkAttributes] = [:]
    var focused: AXUIElement?
    var windowOfFocused: AXUIElement?
    var appWindows: [AXUIElement] = []
    var selectedText: String?
    var focusedRole = "AXTextArea"
    var acceptsManualAccessibility = false
    /// Walk reads that return nothing before the tree appears (Chromium).
    var hiddenReads = 0
    private(set) var reads: [pid_t] = []
    private(set) var manualAccessibilityRequests = 0

    func node(_ role: String, _ text: String? = nil, title: String? = nil, subrole: String? = nil,
              frame: CGRect? = nil, minimized: Bool = false, _ children: [AXUIElement] = []) -> AXUIElement {
        nextID += 1
        let element = AXUIElementCreateApplication(nextID)
        nodes[nextID] = AXWalkAttributes(role: role, subrole: subrole, value: text, title: title,
                                         children: children, frame: frame, isMinimized: minimized)
        return element
    }

    func setChildren(_ element: AXUIElement, _ children: [AXUIElement]) {
        nodes[key(element)]?.children = children
    }

    func key(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    func focusedElement(frontmostPID: pid_t) -> AXUIElement? { frontmostPID == appPID ? focused : nil }
    func pid(of element: AXUIElement) -> pid_t? { appPID }
    func string(_ attribute: String, of element: AXUIElement) -> String? {
        switch attribute {
        case kAXSelectedTextAttribute as String: selectedText
        case kAXRoleAttribute as String: focusedRole
        default: nil
        }
    }
    func valueLength(of element: AXUIElement) -> Int? { nil }
    func selectedRange(of element: AXUIElement) -> CFRange? { nil }
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool { false }
    func setSelectedText(_ text: String, on element: AXUIElement) -> Bool { false }
    func precedingCharacter(of element: AXUIElement, range: CFRange) -> String? { nil }
    func frame(of element: AXUIElement) -> CGRect? { nil }
    func caretFrame(of element: AXUIElement, range: CFRange) -> CGRect? { nil }
    func window(of element: AXUIElement) -> AXUIElement? { windowOfFocused }
    func enableManualAccessibility(pid: pid_t) -> Bool {
        manualAccessibilityRequests += 1
        return acceptsManualAccessibility
    }
    func windows(ofApplication pid: pid_t) -> [AXUIElement] { pid == appPID ? appWindows : [] }
    func walkAttributes(of element: AXUIElement) -> AXWalkAttributes? {
        reads.append(key(element))
        guard let attributes = nodes[key(element)] else { return nil }
        if hiddenReads > 0, attributes.role != "AXWindow" {
            hiddenReads -= 1
            return AXWalkAttributes(role: "AXGroup")
        }
        return attributes
    }
}

final class SourceTextCollectorTests: XCTestCase {
    private let options = SourceTextOptions(manualAccessibilityWait: .milliseconds(500))

    func testCollectsWindowTextWithTheSkipRules() async {
        let ax = TreeAX()
        let composer = ax.node("AXTextArea", "My unfinished draft")
        let secure = ax.node("AXSecureTextField", "hunter22", [ax.node("AXStaticText", "secret child text")])
        let window = ax.node("AXWindow", title: "Thread", [
            ax.node("AXMenuBar", nil, [ax.node("AXMenuBarItem", "File menu item")]),
            ax.node("AXHeading", "Hi"),
            ax.node("AXButton", title: "OK"),
            ax.node("AXStaticText", "Can you do Thursday?"),
            ax.node("AXStaticText", "Can you do Thursday?"),
            ax.node("AXGroup", nil, [ax.node("AXStaticText", "Friday works too.")]),
            ax.node("AXScrollBar", nil, [ax.node("AXStaticText", "scroll bar value")]),
            secure,
            composer,
        ])
        ax.focused = composer
        ax.windowOfFocused = window
        ax.appWindows = [window]
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)

        XCTAssertNil(sources.selectedText)
        XCTAssertNil(sources.copiedText)
        XCTAssertEqual(sources.screenText, [WindowText(title: "Thread", isFocused: true,
                                                       text: "Hi\nCan you do Thursday?\nFriday works too.")])
        XCTAssertFalse(sources.truncated)
    }

    func testReplyCaseReadsTheViewerBehindTheComposeWindow() async {
        let ax = TreeAX()
        let body = ax.node("AXWebArea", nil, [ax.node("AXStaticText", "Draft reply")])
        let compose = ax.node("AXWindow", title: "Re: Thursday", frame: CGRect(x: 0, y: 0, width: 400, height: 300), [body])
        let viewer = ax.node("AXWindow", title: "Inbox", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), [
            ax.node("AXStaticText", "Are you free on Thursday afternoon?"),
        ])
        let small = ax.node("AXWindow", title: "Dialog", frame: CGRect(x: 0, y: 0, width: 100, height: 100), [
            ax.node("AXStaticText", "A small dialog"),
        ])
        let minimized = ax.node("AXWindow", title: "Old draft", minimized: true, [ax.node("AXStaticText", "Hidden away")])
        ax.focused = body
        ax.windowOfFocused = compose
        ax.appWindows = [small, minimized, viewer, compose]
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)

        XCTAssertEqual(sources.screenText.map(\.title), ["Re: Thursday", "Inbox", "Dialog"])
        XCTAssertEqual(sources.screenText.map(\.isFocused), [true, false, false])
        XCTAssertEqual(sources.screenText[0].text, "Draft reply")
        XCTAssertEqual(sources.screenText[1].text, "Are you free on Thursday afternoon?")
    }

    func testApplicationElementLoopsAndSelfReferencesTerminate() async {
        let ax = TreeAX()
        let window = ax.node("AXWindow", title: "Loop", [ax.node("AXStaticText", "Visible message")])
        let app = ax.node("AXApplication", nil, [window])
        ax.setChildren(window, [ax.node("AXStaticText", "Visible message"), app, window])
        ax.appWindows = [window]
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)

        XCTAssertEqual(sources.screenText.first?.text, "Visible message")
        XCTAssertLessThan(ax.reads.count, 20)
    }

    func testListsAreCappedAndWalkedAfterTheirSiblings() async {
        let ax = TreeAX()
        let rows = (1...60).map { ax.node("AXRow", nil, [ax.node("AXStaticText", "Message row \($0)")]) }
        let window = ax.node("AXWindow", title: "Mail", [
            ax.node("AXTable", nil, rows),
            ax.node("AXStaticText", "The body of the open message"),
        ])
        ax.appWindows = [window]
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)
        let lines = sources.screenText.first?.text.components(separatedBy: "\n") ?? []

        XCTAssertEqual(lines.first, "The body of the open message")
        XCTAssertEqual(lines.count, 1 + SourceTextCollector.rowCap)
        XCTAssertEqual(lines.last, "Message row 40")
    }

    func testElementBudgetStopsTheWalkAndMarksItTruncated() async {
        let ax = TreeAX()
        let window = ax.node("AXWindow", title: "Long", (1...50).map { ax.node("AXStaticText", "Paragraph number \($0)") })
        ax.appWindows = [window]
        var limited = options
        limited.elementBudget = 11
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: nil, options: limited)

        XCTAssertEqual(sources.screenText.first?.text.components(separatedBy: "\n").count, 10)
        XCTAssertTrue(sources.truncated)
    }

    func testCapKeepsSelectionThenCopiedTextThenScreen() async {
        let ax = TreeAX()
        let field = ax.node("AXTextArea", "whole field")
        let window = ax.node("AXWindow", title: "Notes", [ax.node("AXStaticText", "Screen text that will not fit")])
        ax.focused = field
        ax.windowOfFocused = window
        ax.appWindows = [window]
        ax.selectedText = "0123456789"
        var small = options
        small.characterLimit = 15
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: "abcdefghij", options: small)

        XCTAssertEqual(sources.selectedText, "0123456789")
        XCTAssertEqual(sources.copiedText, "abcde")
        XCTAssertEqual(sources.screenText, [])
        XCTAssertTrue(sources.truncated)
    }

    func testSourceTogglesAndSecureFocusedField() async {
        let ax = TreeAX()
        let field = ax.node("AXSecureTextField")
        let window = ax.node("AXWindow", title: "Login", [ax.node("AXStaticText", "Sign in to continue")])
        ax.focused = field
        ax.focusedRole = "AXSecureTextField"
        ax.windowOfFocused = window
        ax.appWindows = [window]
        ax.selectedText = "password"
        var off = options
        off.usesScreenText = false
        off.usesCopiedText = false
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: "copied", options: off)

        XCTAssertTrue(sources.isEmpty)
        XCTAssertTrue(ax.reads.isEmpty)
    }

    func testScribesOwnWindowsAreNeverRead() async {
        let ax = TreeAX()
        ax.appWindows = [ax.node("AXWindow", title: "Settings", [ax.node("AXStaticText", "Scribe settings text")])]
        let collector = SourceTextCollector(client: ax, ownPID: ax.appPID)

        let sources = await collector.collect(pid: ax.appPID, clipboardText: "copied text", options: options)

        XCTAssertEqual(sources, GatheredSources(copiedText: "copied text"))
        XCTAssertTrue(ax.reads.isEmpty)
    }

    func testWaitsForTheChromiumTreeOncePerProcess() async {
        let ax = TreeAX()
        let window = ax.node("AXWindow", title: "Slack", [ax.node("AXGroup", nil, [ax.node("AXStaticText", "Message in the channel")])])
        ax.appWindows = [window]
        ax.acceptsManualAccessibility = true
        ax.hiddenReads = 4
        let collector = SourceTextCollector(client: ax, ownPID: 1)

        let first = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)
        _ = await collector.collect(pid: ax.appPID, clipboardText: nil, options: options)

        XCTAssertEqual(first.screenText.first?.text, "Message in the channel")
        XCTAssertEqual(ax.manualAccessibilityRequests, 1)
    }

    func testHintNamesTheSourcesInUse() {
        XCTAssertEqual(GatheredSources(selectedText: "x").hint(applicationName: "Notes"), "Using your selection")
        XCTAssertEqual(
            GatheredSources(copiedText: "x", screenText: [WindowText(title: nil, isFocused: true, text: "y")]).hint(applicationName: "Mail"),
            "Using copied text and what is on screen in Mail"
        )
        XCTAssertEqual(
            GatheredSources(screenText: [WindowText(title: nil, isFocused: true, text: "y")]).hint(applicationName: "Slack"),
            "Using what is on screen in Slack"
        )
        XCTAssertEqual(
            GatheredSources(selectedText: "a", copiedText: "b", screenText: [WindowText(title: nil, isFocused: true, text: "c")]).hint(applicationName: nil),
            "Using your selection, copied text and what is on screen"
        )
        XCTAssertNil(GatheredSources().hint(applicationName: "Mail"))
    }

    func testRequestCarriesEveryBlock() {
        let sources = GatheredSources(selectedText: "sel", copiedText: "copy",
                                      screenText: [WindowText(title: "W", isFocused: true, text: "screen")], truncated: true)
        let request = sources.request(instruction: "make it shorter", applicationName: "Mail", locale: "en_GB")
        XCTAssertEqual(request, AssistRequest(instruction: "make it shorter", selectedText: "sel", copiedText: "copy",
                                              screenText: [WindowText(title: "W", isFocused: true, text: "screen")],
                                              truncated: true, applicationName: "Mail", locale: "en_GB"))
    }

    func testClipboardIsFreshOnlyWhenItChangedSinceTheLastRequest() {
        var freshness = ClipboardFreshness()
        XCTAssertTrue(freshness.take(changeCount: 7), "no previous request: whatever is there counts")
        XCTAssertFalse(freshness.take(changeCount: 7))
        XCTAssertTrue(freshness.take(changeCount: 8))
        // Scribe's paste fallback bumps the count; that is not the person's copy.
        freshness.adoptOwnChange(before: 8, after: 10)
        XCTAssertFalse(freshness.take(changeCount: 10))
        // A copy made in between is kept as fresh.
        freshness.adoptOwnChange(before: 9, after: 12)
        XCTAssertTrue(freshness.take(changeCount: 12))
    }
}
