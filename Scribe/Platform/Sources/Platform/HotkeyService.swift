import Carbon.HIToolbox
import Foundation

/// A globally registered shortcut expressed in Carbon virtual-key coordinates.
public struct GlobalShortcut: Codable, Hashable, Sendable, Identifiable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public var id: String { "\(keyCode)-\(modifiers)" }

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultStart = GlobalShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey))
    public static let defaultStop = GlobalShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))

    public static let commonChoices: [GlobalShortcut] = [
        .defaultStart,
        .defaultStop,
        GlobalShortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey)),
        GlobalShortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))
    ]

    public var displayName: String {
        let modifierText = [
            modifiers & UInt32(controlKey) != 0 ? "⌃" : nil,
            modifiers & UInt32(optionKey) != 0 ? "⌥" : nil,
            modifiers & UInt32(shiftKey) != 0 ? "⇧" : nil,
            modifiers & UInt32(cmdKey) != 0 ? "⌘" : nil
        ].compactMap { $0 }.joined()
        return modifierText + Self.keyName(for: keyCode)
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_R): "R"
        case UInt32(kVK_ANSI_S): "S"
        case UInt32(kVK_ANSI_1): "1"
        case UInt32(kVK_ANSI_2): "2"
        default: "Key \(keyCode)"
        }
    }
}

/// The coordinator boundary used by both global shortcuts and the future menu.
@MainActor
public protocol RecordingShortcutCoordinating: AnyObject {
    func startRecordingFromShortcut()
    func stopRecordingFromShortcut()
}

public enum HotkeyAction: String, CaseIterable, Sendable {
    case start
    case stop
}

public enum HotkeyRegistrationFailure: Error, Equatable, Sendable, LocalizedError {
    case duplicateShortcut
    case systemConflict(status: Int32)
    case systemError(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .duplicateShortcut:
            "Start and stop cannot use the same global shortcut."
        case .systemConflict:
            "That global shortcut is already registered by another application."
        case .systemError:
            "macOS could not register that global shortcut."
        }
    }
}

public struct HotkeyRegistrationReport: Equatable, Sendable {
    public let activeActions: Set<HotkeyAction>
    public let failures: [HotkeyAction: HotkeyRegistrationFailure]

    public init(activeActions: Set<HotkeyAction>, failures: [HotkeyAction: HotkeyRegistrationFailure]) {
        self.activeActions = activeActions
        self.failures = failures
    }

    public var hasConflicts: Bool { !failures.isEmpty }
}

/// Testable abstraction around `RegisterEventHotKey`.
@MainActor
public protocol HotKeyRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws
    func unregisterAll()
}

/// Registers independent start/stop shortcuts and routes them to one coordinator.
/// Repeated hardware events for the same action are suppressed for a short window.
@MainActor
public final class HotkeyService {
    public private(set) var lastRegistrationReport = HotkeyRegistrationReport(activeActions: [], failures: [:])

    private weak var coordinator: (any RecordingShortcutCoordinating)?
    private let registrar: any HotKeyRegistering
    private let debounceInterval: TimeInterval
    private var lastEventDate: [HotkeyAction: Date] = [:]

    public init(
        coordinator: any RecordingShortcutCoordinating,
        registrar: any HotKeyRegistering = CarbonHotKeyRegistrar(),
        debounceInterval: TimeInterval = 0.35
    ) {
        self.coordinator = coordinator
        self.registrar = registrar
        self.debounceInterval = debounceInterval
    }

    /// Replaces the current registrations. Failures are returned to the caller
    /// so menu recording remains available and the user can choose another key.
    @discardableResult
    public func register(start: GlobalShortcut, stop: GlobalShortcut) -> HotkeyRegistrationReport {
        registrar.unregisterAll()
        lastEventDate.removeAll()

        guard start != stop else {
            let report = HotkeyRegistrationReport(
                activeActions: [],
                failures: [.start: .duplicateShortcut, .stop: .duplicateShortcut]
            )
            lastRegistrationReport = report
            return report
        }

        var active = Set<HotkeyAction>()
        var failures: [HotkeyAction: HotkeyRegistrationFailure] = [:]
        register(start, action: .start, identifier: 1, active: &active, failures: &failures)
        register(stop, action: .stop, identifier: 2, active: &active, failures: &failures)
        let report = HotkeyRegistrationReport(activeActions: active, failures: failures)
        lastRegistrationReport = report
        return report
    }

    public func unregisterAll() {
        registrar.unregisterAll()
        lastRegistrationReport = HotkeyRegistrationReport(activeActions: [], failures: [:])
    }

    /// Allows deterministic tests to exercise the same debounced dispatch path
    /// that the Carbon event handler uses.
    public func handleEvent(for action: HotkeyAction, at date: Date = Date()) {
        if let lastEvent = lastEventDate[action], date.timeIntervalSince(lastEvent) < debounceInterval {
            return
        }
        lastEventDate[action] = date
        switch action {
        case .start: coordinator?.startRecordingFromShortcut()
        case .stop: coordinator?.stopRecordingFromShortcut()
        }
    }

    private func register(
        _ shortcut: GlobalShortcut,
        action: HotkeyAction,
        identifier: UInt32,
        active: inout Set<HotkeyAction>,
        failures: inout [HotkeyAction: HotkeyRegistrationFailure]
    ) {
        do {
            try registrar.register(shortcut, identifier: identifier) { [weak self] in
                self?.handleEvent(for: action)
            }
            active.insert(action)
        } catch let failure as HotkeyRegistrationFailure {
            failures[action] = failure
        } catch {
            failures[action] = .systemError(status: -1)
        }
    }
}

/// AppKit/Carbon implementation of the low-level global shortcut API.
@MainActor
public final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: @MainActor () -> Void] = [:]

    public init() {}

    public func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws {
        try installEventHandlerIfNeeded()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53435242), id: identifier) // "SCRB"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            if status == eventHotKeyExistsErr {
                throw HotkeyRegistrationFailure.systemConflict(status: status)
            }
            throw HotkeyRegistrationFailure.systemError(status: status)
        }
        registrations[identifier] = hotKeyRef
        actions[identifier] = action
    }

    public func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration)
        }
        registrations.removeAll()
        actions.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            throw HotkeyRegistrationFailure.systemError(status: status)
        }
    }

    fileprivate func invoke(identifier: UInt32) {
        actions[identifier]?()
    }
}

private let carbonHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let registrar = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        registrar.invoke(identifier: hotKeyID.id)
    }
    return noErr
}
