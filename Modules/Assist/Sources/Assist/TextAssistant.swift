import Foundation

/// Something that turns a spoken instruction and the text in front of the
/// person into the text to insert. The dictation coordinator only knows this
/// protocol; the account type and the HTTP details stay in this module.
public protocol TextAssistant: Sendable {
    /// Named in the indicator while the request runs, e.g. "ChatGPT".
    var displayName: String { get }
    func respond(to request: AssistRequest) async throws -> AssistResponse
}

/// One request, gathered at key-down and completed with the transcript at key-up.
public struct AssistRequest: Sendable, Equatable {
    /// The transcribed utterance.
    public var instruction: String
    /// `AXSelectedText` of the focused field, when non-empty.
    public var selectedText: String?
    /// The clipboard, only when it changed since the previous request.
    public var copiedText: String?
    /// Per visible window of the frontmost app, focused window first.
    public var screenText: [WindowText]
    /// True when any block was cut to fit the size cap.
    public var truncated: Bool
    /// The frontmost app, e.g. "Mail".
    public var applicationName: String?
    /// For the reply-language default, e.g. "en_GB".
    public var locale: String

    public init(
        instruction: String,
        selectedText: String? = nil,
        copiedText: String? = nil,
        screenText: [WindowText] = [],
        truncated: Bool = false,
        applicationName: String? = nil,
        locale: String = Locale.current.identifier
    ) {
        self.instruction = instruction
        self.selectedText = selectedText
        self.copiedText = copiedText
        self.screenText = screenText
        self.truncated = truncated
        self.applicationName = applicationName
        self.locale = locale
    }
}

/// The text read from one window of the frontmost app.
public struct WindowText: Sendable, Equatable {
    public var title: String?
    public var isFocused: Bool
    public var text: String

    public init(title: String?, isFocused: Bool, text: String) {
        self.title = title
        self.isFocused = isFocused
        self.text = text
    }
}

public struct AssistResponse: Sendable, Equatable {
    /// The text to insert, exactly as the model returned it.
    public var text: String
    /// The model that answered, for the indicator.
    public var model: String
    public var usage: AssistUsage?

    public init(text: String, model: String, usage: AssistUsage? = nil) {
        self.text = text
        self.model = model
        self.usage = usage
    }

    /// A short line for the indicator, e.g. "1,204 in · 180 out".
    public var usageLine: String? {
        guard let usage else { return nil }
        return "\(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out"
    }
}

public struct AssistUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What went wrong, in the terms the indicator and Settings show.
public enum AssistError: Error, Equatable, Sendable, LocalizedError {
    /// The ChatGPT sign-in is missing, expired or revoked (401, or a refresh error).
    case signInRequired
    /// The ChatGPT plan's Codex limit is used up (429); `resetsAt` when the backend said.
    case usageLimitReached(resetsAt: Date?)
    /// The backend refused this account (403: the plan has no Codex, or the route is closed).
    case notAvailableForAccount
    /// The OpenAI API key is missing or was rejected (401).
    case invalidAPIKey
    /// The API key's rate or quota limit (429).
    case rateLimited(retryAfter: TimeInterval?, message: String?)
    /// The chosen model is no longer offered to this account.
    case modelUnavailable(String)
    /// The model answered with no text.
    case emptyResponse
    case network(String)
    case server(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .signInRequired:
            "Sign in to ChatGPT again to use Voice Assistant."
        case .usageLimitReached(let resetsAt):
            if let resetsAt {
                "ChatGPT usage limit reached. It resets at \(resetsAt.formatted(Self.resetStyle(for: resetsAt)))."
            } else {
                "ChatGPT usage limit reached. Try again later."
            }
        case .notAvailableForAccount:
            "Voice Assistant is not available for this ChatGPT account."
        case .invalidAPIKey:
            "OpenAI did not accept the API key."
        case .rateLimited(_, let message):
            message ?? "OpenAI’s rate limit was reached. Try again shortly."
        case .modelUnavailable(let model):
            "\(model) is no longer offered to this account. Choose another model in Settings."
        case .emptyResponse:
            "The model returned no text."
        case .network(let message):
            message
        case .server(let status, let message):
            message.map { "OpenAI returned an error (\(status)): \($0)" } ?? "OpenAI returned an error (\(status))."
        }
    }

    /// The time alone when the reset is today, the day and time otherwise.
    private static func resetStyle(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).hour().minute()
    }
}
