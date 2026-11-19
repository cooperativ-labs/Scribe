import Platform
import XCTest

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testShortcutEventsInvokeCoordinatorAndDebounceRepeats() {
        let coordinator = RecordingCoordinatorHarness()
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: coordinator, registrar: registrar, debounceInterval: 1)

        let report = service.register(start: .defaultStart, stop: .defaultStop)
        XCTAssertEqual(report.activeActions, [.start, .stop, .pasteTimestamp])

        let instant = Date()
        registrar.fire(identifier: 1)
        service.handleEvent(for: .start, at: instant.addingTimeInterval(0.5))
        service.handleEvent(for: .stop, at: instant.addingTimeInterval(0.5))
        registrar.fire(identifier: 3)

        XCTAssertEqual(coordinator.startInvocations, 1)
        XCTAssertEqual(coordinator.stopInvocations, 1)
        XCTAssertEqual(coordinator.pasteInvocations, 1)
    }

    func testRecordedShortcutsNameAnyKey() {
        // ⌥⌘K (kVK_ANSI_K = 40), ⌃F5 (kVK_F5 = 96), ⌘Space (kVK_Space = 49).
        XCTAssertEqual(GlobalShortcut(keyCode: 40, modifiers: 256 | 2048).displayName, "⌥⌘K")
        XCTAssertEqual(GlobalShortcut(keyCode: 96, modifiers: 4096).displayName, "⌃F5")
        XCTAssertEqual(GlobalShortcut(keyCode: 49, modifiers: 256).displayName, "⌘Space")
        XCTAssertEqual(GlobalShortcut(keyCode: 40, modifiers: 256).keyEquivalentCharacter, "k")
        XCTAssertEqual(GlobalShortcut(keyCode: 96, modifiers: 0).keyEquivalentCharacter, "\u{F708}")
        XCTAssertEqual(GlobalShortcut.defaultStart.displayName, "⇧⌘R")
    }

    func testGlobalShortcutsNeedACommandModifierUnlessOnAFunctionKey() {
        XCTAssertTrue(GlobalShortcut(keyCode: 40, modifiers: 256).isAcceptableGlobalShortcut)
        XCTAssertTrue(GlobalShortcut(keyCode: 40, modifiers: 4096).isAcceptableGlobalShortcut)
        XCTAssertTrue(GlobalShortcut(keyCode: 96, modifiers: 0).isAcceptableGlobalShortcut)
        XCTAssertFalse(GlobalShortcut(keyCode: 40, modifiers: 0).isAcceptableGlobalShortcut)
        XCTAssertFalse(GlobalShortcut(keyCode: 40, modifiers: 512).isAcceptableGlobalShortcut)
        // A bare modifier key (kVK_Command = 55) is never a shortcut.
        XCTAssertFalse(GlobalShortcut(keyCode: 55, modifiers: 256).isAcceptableGlobalShortcut)
    }

    func testConflictsAreReportedWithoutPreventingTheOtherShortcut() {
        let coordinator = RecordingCoordinatorHarness()
        let registrar = HotKeyRegistrarHarness(conflictingShortcut: .defaultStop)
        let service = HotkeyService(coordinator: coordinator, registrar: registrar)

        let report = service.register(start: .defaultStart, stop: .defaultStop)

        XCTAssertEqual(report.activeActions, [.start, .pasteTimestamp])
        XCTAssertEqual(report.failures[.stop], .systemConflict(status: -9878))
    }

    func testDuplicateShortcutsAreReportedBeforeRegistering() {
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: RecordingCoordinatorHarness(), registrar: registrar)

        let report = service.register(start: .defaultStart, stop: .defaultStart)

        XCTAssertEqual(report.failures[.start], .duplicateShortcut)
        XCTAssertEqual(report.failures[.stop], .duplicateShortcut)
        XCTAssertNil(report.failures[.pasteTimestamp])
        XCTAssertEqual(Set(registrar.registeredActions.keys), [3])
    }

    func testPasteTimestampCannotShareAShortcutWithStartOrStop() {
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: RecordingCoordinatorHarness(), registrar: registrar)

        let report = service.register(
            start: .defaultPasteTimestamp,
            stop: .defaultStop,
            pasteTimestamp: .defaultPasteTimestamp
        )

        XCTAssertEqual(report.failures[.start], .duplicateShortcut)
        XCTAssertEqual(report.failures[.pasteTimestamp], .duplicateShortcut)
        XCTAssertNil(report.failures[.stop])
        XCTAssertEqual(Set(registrar.registeredActions.keys), [2])
    }

    func testTheMeetingNotesShortcutOpensNotesRatherThanDrivingTheRecorder() {
        let coordinator = RecordingCoordinatorHarness()
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: coordinator, registrar: registrar, debounceInterval: 1)
        var opened = 0
        service.openMeetingNotes = { opened += 1 }

        let report = service.register(
            start: .defaultStart,
            stop: .defaultStop,
            pasteTimestamp: .defaultPasteTimestamp,
            meetingNotes: .defaultMeetingNotes
        )
        XCTAssertEqual(report.activeActions, [.start, .stop, .pasteTimestamp, .meetingNotes])
        XCTAssertEqual(GlobalShortcut.defaultMeetingNotes.displayName, "\u{2325}\u{21E7}\u{2318}N")

        registrar.fire(identifier: 4)
        service.handleEvent(for: .meetingNotes, at: Date())
        XCTAssertEqual(opened, 1, "repeats are debounced like the others")
        XCTAssertEqual(coordinator.startInvocations + coordinator.stopInvocations + coordinator.pasteInvocations, 0)
    }

    func testTheMeetingNotesShortcutReportsConflictsAndDuplicatesLikeTheOthers() {
        let registrar = HotKeyRegistrarHarness(conflictingShortcut: .defaultMeetingNotes)
        let service = HotkeyService(coordinator: RecordingCoordinatorHarness(), registrar: registrar)

        let conflicted = service.register(start: .defaultStart, stop: .defaultStop, meetingNotes: .defaultMeetingNotes)
        XCTAssertEqual(conflicted.failures[.meetingNotes], .systemConflict(status: -9878))
        XCTAssertEqual(conflicted.activeActions, [.start, .stop, .pasteTimestamp], "the others still work")
        XCTAssertEqual(conflicted.issueDescriptions, ["Meeting notes shortcut: That global shortcut is already registered by another application."])

        let duplicated = service.register(start: .defaultStart, stop: .defaultStop, meetingNotes: .defaultPasteTimestamp)
        XCTAssertEqual(duplicated.failures[.meetingNotes], .duplicateShortcut)
        XCTAssertEqual(duplicated.failures[.pasteTimestamp], .duplicateShortcut)

        let without = service.register(start: .defaultStart, stop: .defaultStop)
        XCTAssertFalse(without.activeActions.contains(.meetingNotes), "not registered unless asked for")
    }
}

@MainActor
private final class RecordingCoordinatorHarness: RecordingShortcutCoordinating {
    var startInvocations = 0
    var stopInvocations = 0
    var pasteInvocations = 0

    func startRecordingFromShortcut() { startInvocations += 1 }
    func stopRecordingFromShortcut() { stopInvocations += 1 }
    func pasteTimestampFromShortcut() { pasteInvocations += 1 }
}

@MainActor
private final class HotKeyRegistrarHarness: HotKeyRegistering {
    private let conflictingShortcut: GlobalShortcut?
    private(set) var registeredActions: [UInt32: @MainActor () -> Void] = [:]

    init(conflictingShortcut: GlobalShortcut? = nil) {
        self.conflictingShortcut = conflictingShortcut
    }

    func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws {
        if shortcut == conflictingShortcut {
            throw HotkeyRegistrationFailure.systemConflict(status: -9878)
        }
        registeredActions[identifier] = action
    }

    func unregisterAll() {
        registeredActions.removeAll()
    }

    func fire(identifier: UInt32) {
        registeredActions[identifier]?()
    }
}
