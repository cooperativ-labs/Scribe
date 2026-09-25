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
    public static let defaultPasteTimestamp = GlobalShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey))

    public var displayName: String {
        let modifierText = [
            modifiers & UInt32(controlKey) != 0 ? "⌃" : nil,
            modifiers & UInt32(optionKey) != 0 ? "⌥" : nil,
            modifiers & UInt32(shiftKey) != 0 ? "⇧" : nil,
            modifiers & UInt32(cmdKey) != 0 ? "⌘" : nil
        ].compactMap { $0 }.joined()
        return modifierText + (Self.keys[keyCode]?.name ?? "Key \(keyCode)")
    }

    /// Character AppKit menus use for `NSMenuItem.keyEquivalent`. Empty when the
    /// key has no menu equivalent, in which case the menu shows no shortcut.
    public var keyEquivalentCharacter: String {
        Self.keys[keyCode]?.equivalent ?? ""
    }

    /// Whether the key is one of the function keys, which may stand alone as a
    /// global shortcut because typing never produces them.
    public var isFunctionKey: Bool {
        Self.functionKeyCodes.contains(keyCode)
    }

    /// Whether this combination can be claimed globally without stealing
    /// ordinary typing: it needs ⌘, ⌃, or ⌥, unless the key is a function key.
    /// Shift alone is not enough, since ⇧A is just a capital A.
    public var isAcceptableGlobalShortcut: Bool {
        guard Self.keys[keyCode] != nil, !Self.modifierKeyCodes.contains(keyCode) else { return false }
        let hasCommandModifier = modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        return hasCommandModifier || isFunctionKey
    }

    private struct KeyDescription {
        let name: String
        let equivalent: String
    }

    private static let functionKeyCodes: Set<UInt32> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map(UInt32.init))

    private static let modifierKeyCodes: Set<UInt32> = Set([
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function
    ].map(UInt32.init))

    /// Names and menu equivalents by Carbon virtual key. The codes are physical
    /// positions on an ANSI keyboard, so the names are the US labels.
    private static let keys: [UInt32: KeyDescription] = {
        var table: [UInt32: KeyDescription] = [:]
        func add(_ code: Int, _ name: String, _ equivalent: String) {
            table[UInt32(code)] = KeyDescription(name: name, equivalent: equivalent)
        }
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z")
        ]
        for (code, name) in letters { add(code, name, name.lowercased()) }
        let symbols: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."),
            (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`")
        ]
        for (code, name) in symbols { add(code, name, name) }
        // Menu equivalents for the non-printing keys are the private-use
        // characters AppKit defines (NSF1FunctionKey and friends).
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ]
        for (index, code) in functionKeys.enumerated() {
            add(code, "F\(index + 1)", unicode(0xF704 + index))
        }
        add(kVK_Space, "Space", " ")
        add(kVK_Return, "↩", "\r")
        add(kVK_Tab, "⇥", "\t")
        add(kVK_Delete, "⌫", unicode(0x08))
        add(kVK_ForwardDelete, "⌦", unicode(0xF728))
        add(kVK_Escape, "⎋", unicode(0x1B))
        add(kVK_LeftArrow, "←", unicode(0xF702))
        add(kVK_RightArrow, "→", unicode(0xF703))
        add(kVK_UpArrow, "↑", unicode(0xF700))
        add(kVK_DownArrow, "↓", unicode(0xF701))
        add(kVK_Home, "↖", unicode(0xF729))
        add(kVK_End, "↘", unicode(0xF72B))
        add(kVK_PageUp, "⇞", unicode(0xF72C))
        add(kVK_PageDown, "⇟", unicode(0xF72D))
        return table
    }()

    private static func unicode(_ value: Int) -> String {
        String(Character(Unicode.Scalar(UInt32(value))!))
    }

    public var usesControl: Bool { modifiers & UInt32(controlKey) != 0 }
    public var usesOption: Bool { modifiers & UInt32(optionKey) != 0 }
    public var usesShift: Bool { modifiers & UInt32(shiftKey) != 0 }
    public var usesCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
}

/// The coordinator boundary used by both global shortcuts and the future menu.
@MainActor
public protocol RecordingShortcutCoordinating: AnyObject {
    func startRecordingFromShortcut()
    func stopRecordingFromShortcut()
    func pasteTimestampFromShortcut()
}

public enum HotkeyAction: String, CaseIterable, Sendable {
    case start
    case stop
    case pasteTimestamp

    public var displayName: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .pasteTimestamp: "Paste timestamp"
        }
    }

    /// Carbon `RegisterEventHotKey` identifier. Stable so tests can fire a
    /// specific action without depending on registration order.
    var hotKeyIdentifier: UInt32 {
        switch self {
        case .start: 1
        case .stop: 2
        case .pasteTimestamp: 3
        }
    }
}

public enum HotkeyRegistrationFailure: Error, Equatable, Sendable, LocalizedError {
    case duplicateShortcut
    case systemConflict(status: Int32)
    case systemError(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .duplicateShortcut:
            "Each action needs its own global shortcut."
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

    public var issueDescriptions: [String] {
        HotkeyAction.allCases.compactMap { action in
            guard let failure = failures[action] else { return nil }
            return "\(action.displayName) shortcut: \(failure.errorDescription ?? "unavailable")"
        }
    }
}

/// Testable abstraction around `RegisterEventHotKey`.
@MainActor
public protocol HotKeyRegistering: AnyObject {
    func register(_ shortcut: GlobalShortcut, identifier: UInt32, action: @escaping @MainActor () -> Void) throws
    func unregisterAll()
}

/// Registers independent start, stop, and paste-timestamp shortcuts and routes them to one coordinator.
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
    public func register(
        start: GlobalShortcut,
        stop: GlobalShortcut,
        pasteTimestamp: GlobalShortcut = .defaultPasteTimestamp
    ) -> HotkeyRegistrationReport {
        registrar.unregisterAll()
        lastEventDate.removeAll()

        let assignments: [(HotkeyAction, GlobalShortcut)] = [
            (.start, start),
            (.stop, stop),
            (.pasteTimestamp, pasteTimestamp)
        ]

        var failures: [HotkeyAction: HotkeyRegistrationFailure] = [:]
        for i in assignments.indices {
            for j in assignments.indices where j > i {
                if assignments[i].1 == assignments[j].1 {
                    failures[assignments[i].0] = .duplicateShortcut
                    failures[assignments[j].0] = .duplicateShortcut
                }
            }
        }

        var active = Set<HotkeyAction>()
        for (action, shortcut) in assignments {
            guard failures[action] == nil else { continue }
            register(
                shortcut,
                action: action,
                identifier: action.hotKeyIdentifier,
                active: &active,
                failures: &failures
            )
        }
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
        case .pasteTimestamp: coordinator?.pasteTimestampFromShortcut()
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
