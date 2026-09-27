/// Modifier keys available for hold and double-tap dictation and the voice
/// assistant. Both modes choose from this one list, and never the same entry.
public enum DictationActivationKey: String, CaseIterable, Identifiable, Sendable {
    case rightCommand
    case rightShift
    case function
    case rightOption
    case rightControl
    case leftControl
    case leftOption
    /// Fn and Control held together, in either order. The only entry that is
    /// not a single key: the trigger monitor derives its press and release
    /// from the modifier flags and feeds the state machine `keyCode`.
    case functionControl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightCommand: "Right Command (⌘)"
        case .rightShift: "Right Shift (⇧)"
        case .function: "Fn / Globe (🌐)"
        case .rightOption: "Right Option (⌥)"
        case .rightControl: "Right Control (⌃)"
        case .leftControl: "Left Control (⌃)"
        case .leftOption: "Left Option (⌥)"
        case .functionControl: "Fn + Control (🌐⌃)"
        }
    }

    /// The name without its symbol, for sentences such as "Hold Right Shift and speak".
    public var shortName: String {
        switch self {
        case .rightCommand: "Right Command"
        case .rightShift: "Right Shift"
        case .function: "Fn"
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .leftControl: "Left Control"
        case .leftOption: "Left Option"
        case .functionControl: "Fn + Control"
        }
    }

    /// The virtual key code of the key's `flagsChanged` events. The chord has
    /// no key code of its own, so it takes one no keyboard sends.
    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .rightShift: 60
        case .function: 63
        case .rightOption: 61
        case .rightControl: 62
        case .leftControl: 59
        case .leftOption: 58
        case .functionControl: Self.chordKeyCode
        }
    }

    public static let chordKeyCode: UInt16 = 0xFFFF

    /// True for Fn and the chord, which both depend on the Fn key reaching macOS.
    public var usesFunctionKey: Bool { self == .function || self == .functionControl }

    /// True for keys that also type: Option composes accented characters and
    /// Control moves the cursor, so a quick press is discarded, not inserted.
    public var isTypingModifier: Bool { self == .leftOption || self == .leftControl }
}
