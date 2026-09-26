/// Modifier keys available for hold and double-tap dictation.
public enum DictationActivationKey: String, CaseIterable, Identifiable, Sendable {
    case rightCommand
    case rightShift
    case function

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightCommand: "Right Command (⌘)"
        case .rightShift: "Right Shift (⇧)"
        case .function: "Fn / Globe (🌐)"
        }
    }

    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: 54
        case .rightShift: 60
        case .function: 63
        }
    }
}
