import AppKit
import Carbon.HIToolbox

/// AppKit is the preferred event source from the feasibility spike. Its global
/// callbacks are observe-only; the focused application's keys remain untouched.
@MainActor
public final class DictationTriggerMonitor {
    public var onEvent: (@MainActor (DictationTriggerEvent) -> Void)?
    public var onSecureInputChange: (@MainActor (Bool) -> Void)?
    public var onRightCommandObserved: (@MainActor () -> Void)?
    public var state = DictationTriggerState()
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var rightDown = false
    private var secureInputBlocked = false

    public init() {}

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
                self.emit(self.state.advance(to: ProcessInfo.processInfo.systemUptime))
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
        rightDown = false
        if secureInputBlocked {
            secureInputBlocked = false
            onSecureInputChange?(false)
        }
        emit(state.cancel(.stopped))
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 54 else { return }
        onRightCommandObserved?()
        // The general .command flag stays set if left Command is also down.
        // Track keycode-54 edges instead; keyState returned false during held
        // physical keys in the signed macOS 27 feasibility probe.
        rightDown.toggle()
        handle(keyCode: event.keyCode, isDown: rightDown, time: event.timestamp)
    }

    private func handleKey(_ event: NSEvent) {
        if event.keyCode == 53, state.isToggleActive {
            emit(state.cancel(.stopped))
            return
        }
        handle(keyCode: event.keyCode, isDown: true, time: event.timestamp)
    }

    public func stopToggle() {
        guard state.isToggleActive else { return }
        emit(state.finishToggle())
    }

    public func cancelToggle() {
        guard state.isToggleActive else { return }
        emit(state.cancel(.stopped))
    }

    private func handle(keyCode: UInt16, isDown: Bool, time: TimeInterval) {
        let secure = IsSecureEventInputEnabled()
        if secure != secureInputBlocked { refreshSecureInput() }
        emit(state.handle(DictationKeyEvent(time: time, keyCode: keyCode, isDown: isDown), secureInput: secure))
    }

    private func refreshSecureInput() {
        let blocked = IsSecureEventInputEnabled()
        guard blocked != secureInputBlocked else { return }
        secureInputBlocked = blocked
        onSecureInputChange?(blocked)
        if blocked {
            emit(state.cancel(.secureInput))
            emit([.secureInputBlocked])
        }
    }

    private func emit(_ events: [DictationTriggerEvent]) {
        for event in events { onEvent?(event) }
    }
}
