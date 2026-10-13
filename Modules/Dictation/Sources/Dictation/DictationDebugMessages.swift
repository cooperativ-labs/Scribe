import Platform

extension DictationState {
    /// Mirrors indicator copy without retaining speech, previews or responses.
    var debugStatus: (message: String, level: MessageDebugEntry.Level) {
        switch self {
        case .idle: ("Idle", .status)
        case .warming: ("Loading model…", .status)
        case .listening: ("Listening", .status)
        case .transcribing: ("Transcribing…", .status)
        case .inserted(let application): (application.map { "Inserted in \($0)" } ?? "Inserted", .status)
        case .unverifiedPaste: ("Sent to app. If missing, press ⌘V", .warning)
        case .copied: ("Copied. Press ⌘V", .status)
        case .error(let message): (message, .error)
        case .secureInputBlocked: (DictationState.secureInputMessage, .warning)
        case .thinking(let assistant, let model): ("Asking \(assistant)…" + (model.map { " (\($0))" } ?? ""), .status)
        case .nothingToWorkWith(let application): (application.map { "Nothing to work with in \($0)" } ?? "Nothing to work with", .warning)
        case .signInRequired(let message): (message, .warning)
        }
    }
}

extension DictationTriggerEvent {
    var debugMessage: String {
        switch self {
        case .listeningStarted(let mode, let intent): "Listening started (\(intent), \(mode))"
        case .listeningEnded(let intent): "Listening ended (\(intent))"
        case .cancelled(let reason, let intent): "Listening cancelled (\(intent), reason=\(reason))"
        case .secureInputBlocked(let intent): "Activation blocked by Secure Keyboard Entry (\(intent))"
        }
    }
}
