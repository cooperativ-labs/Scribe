import Platform
import XCTest

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testShortcutEventsInvokeCoordinatorAndDebounceRepeats() {
        let coordinator = RecordingCoordinatorHarness()
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: coordinator, registrar: registrar, debounceInterval: 1)

        let report = service.register(start: .defaultStart, stop: .defaultStop)
        XCTAssertEqual(report.activeActions, [.start, .stop])

        let instant = Date()
        registrar.fire(identifier: 1)
        service.handleEvent(for: .start, at: instant.addingTimeInterval(0.5))
        service.handleEvent(for: .stop, at: instant.addingTimeInterval(0.5))

        XCTAssertEqual(coordinator.startInvocations, 1)
        XCTAssertEqual(coordinator.stopInvocations, 1)
    }

    func testConflictsAreReportedWithoutPreventingTheOtherShortcut() {
        let coordinator = RecordingCoordinatorHarness()
        let registrar = HotKeyRegistrarHarness(conflictingShortcut: .defaultStop)
        let service = HotkeyService(coordinator: coordinator, registrar: registrar)

        let report = service.register(start: .defaultStart, stop: .defaultStop)

        XCTAssertEqual(report.activeActions, [.start])
        XCTAssertEqual(report.failures[.stop], .systemConflict(status: -9878))
    }

    func testDuplicateShortcutsAreReportedBeforeRegistering() {
        let registrar = HotKeyRegistrarHarness()
        let service = HotkeyService(coordinator: RecordingCoordinatorHarness(), registrar: registrar)

        let report = service.register(start: .defaultStart, stop: .defaultStart)

        XCTAssertEqual(report.failures[.start], .duplicateShortcut)
        XCTAssertEqual(report.failures[.stop], .duplicateShortcut)
        XCTAssertTrue(registrar.registeredActions.isEmpty)
    }
}

@MainActor
private final class RecordingCoordinatorHarness: RecordingShortcutCoordinating {
    var startInvocations = 0
    var stopInvocations = 0

    func startRecordingFromShortcut() { startInvocations += 1 }
    func stopRecordingFromShortcut() { stopInvocations += 1 }
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
