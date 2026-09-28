import Foundation

/// The subscription route: the person's ChatGPT plan through the Codex
/// backend, signed in with `ChatGPTSession`. Not an OpenAI-documented
/// integration; Settings says so next to the sign-in.
public struct ChatGPTAssistant: TextAssistant {
    public let displayName = "ChatGPT"
    public var model: String
    public var systemPrompt: String?
    private let session: ChatGPTSession
    private let transport: HTTPTransport

    public init(session: ChatGPTSession, model: String, systemPrompt: String? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.model = model
        self.systemPrompt = systemPrompt
        self.transport = transport
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        let instructions = AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName)
        let input = AssistPrompt.input(for: request)
        var credentials = try await session.credentials()
        do {
            return try await send(instructions: instructions, input: input, credentials: credentials)
        } catch ResponsesError.http(status: 401, _, _) {
            // The access token may have been revoked early: refresh once and retry.
            credentials = try await session.credentials(forceRefresh: true)
            do {
                return try await send(instructions: instructions, input: input, credentials: credentials)
            } catch let error as ResponsesError {
                throw Self.map(error, model: model)
            }
        } catch let error as ResponsesError {
            throw Self.map(error, model: model)
        }
    }

    private func send(instructions: String, input: String, credentials: (accessToken: String, accountID: String)) async throws -> AssistResponse {
        let client = ResponsesClient(
            baseURL: ChatGPTEndpoints.backendBaseURL,
            headers: ChatGPTSession.backendHeaders(accessToken: credentials.accessToken, accountID: credentials.accountID),
            sendsCodexFields: true,
            transport: transport
        )
        let result = try await client.respond(model: model, instructions: instructions, input: input)
        return try result.validatedAssistResponse()
    }

    static func map(_ error: ResponsesError, model: String, now: Date = .now) -> AssistError {
        switch error {
        case .http(let status, let headers, _):
            let body = error.errorBody
            switch status {
            case 401:
                return .signInRequired
            case 403:
                return .notAvailableForAccount
            case 429:
                return .usageLimitReached(resetsAt: body?.resetDate(now: now) ?? Self.headerReset(headers, now: now))
            case 400 where APIKeyErrors.isModelError(body), 404 where APIKeyErrors.isModelError(body):
                return .modelUnavailable(model)
            default:
                return .server(provider: "OpenAI", status: status, message: body?.message)
            }
        case .stream(let code, let message):
            if code == "usage_limit_reached" || code == "rate_limit_exceeded" { return .usageLimitReached(resetsAt: nil) }
            if code == "model_not_found" { return .modelUnavailable(model) }
            return .server(provider: "OpenAI", status: 200, message: message ?? code)
        case .transport(let message):
            return .network(message)
        }
    }

    /// The backend's rate-limit headers, when the body carried no reset time.
    private static func headerReset(_ headers: [String: String], now: Date) -> Date? {
        for name in ["x-codex-primary-reset-after-seconds", "retry-after"] {
            if let seconds = headers[name].flatMap(TimeInterval.init) { return now.addingTimeInterval(seconds) }
        }
        return nil
    }
}

extension AssistModel {
    /// The default of proposal section 10.2: GPT-6 Luna (light) when the
    /// account offers it, else the first model listed.
    public static func preferredDefault(in models: [AssistModel]) -> AssistModel? {
        models.first(where: \.isLunaLight) ?? models.first
    }

    var isLunaLight: Bool {
        let name = "\(slug) \(displayName)".lowercased()
        return name.contains("luna") && name.contains("light")
    }
}
