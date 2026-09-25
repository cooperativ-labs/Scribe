/// The trigger's input is independent of AppKit so physical sequences can be tested.
public struct DictationKeyEvent: Sendable {
    public let time: TimeInterval
    public let keyCode: UInt16
    public let isDown: Bool

    public init(time: TimeInterval, keyCode: UInt16, isDown: Bool) {
        self.time = time
        self.keyCode = keyCode
        self.isDown = isDown
    }
}

import Foundation

public enum DictationTriggerMode: Sendable, Equatable { case hold, doubleTap }
public enum DictationCancellation: Sendable, Equatable { case shortTap, chord, maximumDuration, secureInput, stopped }
public enum DictationTriggerEvent: Sendable, Equatable {
    case listeningStarted(DictationTriggerMode)
    case listeningEnded
    case cancelled(DictationCancellation)
    case secureInputBlocked
}

/// A second short tap opens toggle mode; a later tap closes it. A hold starts
/// immediately so capture does not lose the first syllable, but a short hold is
/// cancelled on release. `advance(to:)` is called by a monitor timer for the cap.
public struct DictationTriggerState: Sendable {
    public var holdThreshold: TimeInterval = 0.3
    public var doubleTapInterval: TimeInterval = 0.4
    public var maximumDuration: TimeInterval = 300
    private var downAt: TimeInterval?
    private var previousTapAt: TimeInterval?
    private var toggledAt: TimeInterval?
    private var toggleKeyDown = false
    private var suppressUntilRelease = false

    public init() {}

    public var isToggleActive: Bool { toggledAt != nil }

    public mutating func finishToggle() -> [DictationTriggerEvent] {
        guard toggledAt != nil else { return [] }
        toggledAt = nil
        toggleKeyDown = false
        openingTapReleased = false
        closingTap = false
        return [.listeningEnded]
    }

    public mutating func handle(_ input: DictationKeyEvent, secureInput: Bool = false) -> [DictationTriggerEvent] {
        if secureInput {
            let events = cancel(.secureInput)
            return events + (input.keyCode == 54 && input.isDown ? [.secureInputBlocked] : [])
        }
        guard input.keyCode == 54 else {
            if input.isDown, downAt != nil {
                suppressUntilRelease = true
                return cancel(.chord, preserveSuppression: true)
            }
            return []
        }
        if input.isDown {
            guard downAt == nil, !toggleKeyDown, !suppressUntilRelease else { return [] }
            if toggledAt != nil {
                closingTap = openingTapReleased
                toggleKeyDown = true
                return []
            }
            if let tap = previousTapAt, input.time - tap <= doubleTapInterval {
                previousTapAt = nil
                toggledAt = input.time
                openingTapReleased = false
                closingTap = false
                toggleKeyDown = true
                return [.listeningStarted(.doubleTap)]
            }
            previousTapAt = nil
            downAt = input.time
            return [.listeningStarted(.hold)]
        }
        if suppressUntilRelease {
            suppressUntilRelease = false
            return []
        }
        if toggleKeyDown {
            toggleKeyDown = false
            if toggledAt != nil, downAt == nil {
                // Release of the opening tap is ignored. The next down/up pair closes.
                if closingTap {
                    toggledAt = nil
                    closingTap = false
                    openingTapReleased = false
                    return [.listeningEnded]
                }
                openingTapReleased = true
            }
            return []
        }
        guard let start = downAt else { return [] }
        downAt = nil
        if input.time - start < holdThreshold {
            previousTapAt = input.time
            return [.cancelled(.shortTap)]
        }
        previousTapAt = nil
        return [.listeningEnded]
    }

    private var openingTapReleased = false
    private var closingTap = false

    public mutating func advance(to time: TimeInterval) -> [DictationTriggerEvent] {
        if let start = downAt, time - start >= maximumDuration { return cancel(.maximumDuration, preserveSuppression: true) }
        if let start = toggledAt, time - start >= maximumDuration { return cancel(.maximumDuration, preserveSuppression: true) }
        return []
    }

    public mutating func cancel(_ reason: DictationCancellation, preserveSuppression: Bool = false) -> [DictationTriggerEvent] {
        let wasListening = downAt != nil || toggledAt != nil
        downAt = nil
        previousTapAt = nil
        toggledAt = nil
        toggleKeyDown = false
        openingTapReleased = false
        closingTap = false
        if !preserveSuppression { suppressUntilRelease = false }
        return wasListening ? [.cancelled(reason)] : []
    }
}
