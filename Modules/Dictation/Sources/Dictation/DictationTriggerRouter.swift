import AppKit
import Foundation
import Platform

/// One `DictationTriggerState` per assigned key, each with its intent, and the
/// routing between them. Independent of the event source so physical sequences
/// across both keys can be tested; `DictationTriggerMonitor` feeds it AppKit
/// events.
///
/// A trigger key going down is an "other key" to every other mode, which is the
/// state machine's existing chord-cancel rule: holding the assistant key while
/// dictation listens cancels the dictation, and the reverse. The Fn + Control
/// chord is derived from the modifier flags on every `flagsChanged` event and
/// reaches its state as a synthetic key, so the state machine needs no change.
public struct DictationTriggerRouter: Sendable {
    private struct Entry: Sendable {
        var state: DictationTriggerState
        /// Whether the chord was down at the previous modifier event.
        var chordDown = false
    }

    private var entries: [Entry] = []

    public var holdThreshold: TimeInterval = 0.3 { didSet { applyTiming() } }
    public var doubleTapInterval: TimeInterval = 0.4 { didSet { applyTiming() } }
    public var maximumDuration: TimeInterval = 300 { didSet { applyTiming() } }

    public init() {}

    /// The key each installed mode listens on.
    public var activationKeys: [DictationIntent: DictationActivationKey] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.state.intent, $0.state.activationKey) })
    }

    public var isToggleActive: Bool { entries.contains { $0.state.isToggleActive } }

    /// Installs, moves, or removes each mode's key. A mode whose key changes or
    /// that is removed is cancelled if it was listening; the other is untouched.
    public mutating func setKeys(_ keys: [DictationIntent: DictationActivationKey]) -> [DictationTriggerEvent] {
        var events: [DictationTriggerEvent] = []
        var next: [Entry] = []
        for intent in DictationIntent.allCases {
            let existing = entries.first { $0.state.intent == intent }
            guard let key = keys[intent] else {
                if var existing { events += existing.state.cancel(.stopped) }
                continue
            }
            if var existing {
                if existing.state.activationKey != key {
                    events += existing.state.setActivationKey(key)
                    existing.chordDown = false
                }
                next.append(existing)
            } else {
                var state = DictationTriggerState(activationKey: key, intent: intent)
                state.holdThreshold = holdThreshold
                state.doubleTapInterval = doubleTapInterval
                state.maximumDuration = maximumDuration
                next.append(Entry(state: state))
            }
        }
        entries = next
        return events
    }

    /// A modifier went down or up. Returns the events and the modes whose key
    /// took part, for the "press the key to check it is detected" rows.
    public mutating func flagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        time: TimeInterval,
        secureInput: Bool = false
    ) -> (events: [DictationTriggerEvent], observed: [DictationIntent]) {
        var events: [DictationTriggerEvent] = []
        var observed: [DictationIntent] = []
        var pressed: [(index: Int, keyCode: UInt16)] = []
        for index in entries.indices {
            let key = entries[index].state.activationKey
            // Side-specific flags distinguish a right release while the left
            // key is still held. Reading each event also recovers after a
            // missed edge; blindly toggling cannot.
            let isDown = key.isPressed(in: flags)
            if key == .functionControl {
                guard isDown != entries[index].chordDown else { continue }
                entries[index].chordDown = isDown
            } else {
                guard keyCode == key.keyCode else { continue }
            }
            observed.append(entries[index].state.intent)
            events += entries[index].state.handle(
                DictationKeyEvent(time: time, keyCode: key.keyCode, isDown: isDown),
                secureInput: secureInput
            )
            if isDown { pressed.append((index, key.keyCode)) }
        }
        if !secureInput {
            for press in pressed {
                for index in entries.indices where index != press.index {
                    events += entries[index].state.handle(DictationKeyEvent(time: time, keyCode: press.keyCode, isDown: true))
                }
            }
        }
        return (events, observed)
    }

    /// A non-modifier key went down: a chord to any mode that is listening.
    /// Escape ends a double-tap session outright.
    public mutating func keyDown(keyCode: UInt16, time: TimeInterval, secureInput: Bool = false) -> [DictationTriggerEvent] {
        var events: [DictationTriggerEvent] = []
        for index in entries.indices {
            if keyCode == Self.escapeKeyCode, entries[index].state.isToggleActive {
                events += entries[index].state.cancel(.stopped)
            } else {
                events += entries[index].state.handle(
                    DictationKeyEvent(time: time, keyCode: keyCode, isDown: true),
                    secureInput: secureInput
                )
            }
        }
        return events
    }

    public mutating func advance(to time: TimeInterval) -> [DictationTriggerEvent] {
        entries.indices.flatMap { entries[$0].state.advance(to: time) }
    }

    public mutating func cancelAll(_ reason: DictationCancellation) -> [DictationTriggerEvent] {
        entries.indices.flatMap { entries[$0].state.cancel(reason) }
    }

    /// The indicator's Stop: inserts whatever the double-tap session heard.
    public mutating func stopToggle() -> [DictationTriggerEvent] {
        entries.indices.flatMap { entries[$0].state.finishToggle() }
    }

    /// The indicator's Cancel: discards the double-tap session.
    public mutating func cancelToggle() -> [DictationTriggerEvent] {
        entries.indices.flatMap { index in
            entries[index].state.isToggleActive ? entries[index].state.cancel(.stopped) : []
        }
    }

    static let escapeKeyCode: UInt16 = 53

    private mutating func applyTiming() {
        for index in entries.indices {
            entries[index].state.holdThreshold = holdThreshold
            entries[index].state.doubleTapInterval = doubleTapInterval
            entries[index].state.maximumDuration = maximumDuration
        }
    }
}
