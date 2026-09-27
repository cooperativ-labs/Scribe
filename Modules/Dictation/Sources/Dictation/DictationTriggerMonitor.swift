import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import Platform

/// AppKit is the preferred event source from the feasibility spike. Its global
/// callbacks are observe-only; the focused application's keys remain untouched.
///
/// One monitor serves both modes: it holds a `DictationTriggerRouter` with a
/// state per assigned key, and every event names the mode it belongs to.
@MainActor
public final class DictationTriggerMonitor {
    public var onEvent: (@MainActor (DictationTriggerEvent) -> Void)?
    public var onSecureInputChange: (@MainActor (Bool) -> Void)?
    public var onActivationKeyObserved: (@MainActor (DictationIntent) -> Void)?
    /// Escape, whether or not a mode is listening, so a request that is
    /// already past the key (the assistant thinking) can be cancelled too.
    public var onEscape: (@MainActor () -> Void)?
    public private(set) var router = DictationTriggerRouter()
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var secureInputBlocked = false

    public init() {}

    public var isRunning: Bool { flagsMonitor != nil }

    public func start() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlags(event) }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
        }
        // Global monitors omit events delivered to Scribe itself.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .flagsChanged { self?.handleFlags(event) }
                else { self?.handleKey(event) }
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshSecureInput()
                self.emit(self.router.advance(to: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    public func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        localMonitor = nil
        timer?.invalidate()
        timer = nil
        if secureInputBlocked {
            secureInputBlocked = false
            onSecureInputChange?(false)
        }
        emit(router.cancelAll(.stopped))
    }

    /// The key each enabled mode listens on. Settings never assign one key to both.
    public func setKeys(_ keys: [DictationIntent: DictationActivationKey]) {
        emit(router.setKeys(keys))
    }

    public func setTiming(holdThreshold: TimeInterval, doubleTapInterval: TimeInterval, maximumDuration: TimeInterval) {
        router.holdThreshold = holdThreshold
        router.doubleTapInterval = doubleTapInterval
        router.maximumDuration = maximumDuration
    }

    private func handleFlags(_ event: NSEvent) {
        let secure = currentSecureInput()
        let result = router.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags, time: event.timestamp, secureInput: secure)
        for intent in result.observed { onActivationKeyObserved?(intent) }
        emit(result.events)
    }

    private func handleKey(_ event: NSEvent) {
        let secure = currentSecureInput()
        emit(router.keyDown(keyCode: event.keyCode, time: event.timestamp, secureInput: secure))
        if event.keyCode == DictationTriggerRouter.escapeKeyCode { onEscape?() }
    }

    public func stopToggle() {
        emit(router.stopToggle())
    }

    public func cancelToggle() {
        emit(router.cancelToggle())
    }

    private func currentSecureInput() -> Bool {
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputBlocked { refreshSecureInput() }
        return secure
    }

    private func refreshSecureInput() {
        let blocked = IsSecureEventInputEnabled()
        guard blocked != secureInputBlocked else { return }
        secureInputBlocked = blocked
        onSecureInputChange?(blocked)
        if blocked {
            emit(router.cancelAll(.secureInput))
            emit([.secureInputBlocked])
        }
    }

    private func emit(_ events: [DictationTriggerEvent]) {
        for event in events { onEvent?(event) }
    }
}

extension DictationActivationKey {
    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightCommand: flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
        case .rightShift: flags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case .function: flags.contains(.function)
        case .rightOption: flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
        case .rightControl: flags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
        case .leftControl: flags.rawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
        case .leftOption: flags.rawValue & UInt(NX_DEVICELALTKEYMASK) != 0
        case .functionControl: flags.contains(.function) && flags.contains(.control)
        }
    }
}
