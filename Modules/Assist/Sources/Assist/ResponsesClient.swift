import Foundation

/// One streamed Responses-API request, written once for both accounts: the
/// ChatGPT backend (`chatgpt.com/backend-api/codex`) and the public API
/// (`api.openai.com/v1`) differ only in base URL and headers.
///
/// The answer is inserted once, at completion, so the stream is only read to
/// concatenate `response.output_text.delta` events and to learn the usage.
public struct ResponsesClient: Sendable {
    public var baseURL: URL
    /// Sent on every request: authorization, account and originator headers.
    public var headers: [String: String]
    /// The Codex backend insists on these fields being present; the public API accepts them.
    public var sendsCodexFields: Bool
    private let transport: HTTPTransport

    public init(baseURL: URL, headers: [String: String], sendsCodexFields: Bool = false, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.headers = headers
        self.sendsCodexFields = sendsCodexFields
        self.transport = transport
    }

    public func respond(model: String, instructions: String, input: String, timeout: TimeInterval = 60) async throws -> ResponsesResult {
        var request = URLRequest(url: baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(model: model, instructions: instructions, input: input))
        return try await transport.stream(request, decoder: ResponsesStreamDecoder(requestedModel: model))
    }

    func body(model: String, instructions: String, input: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": input]],
            ]],
            "store": false,
            "stream": true,
        ]
        if sendsCodexFields {
            // What Codex always sends alongside (codex-rs/core/src/client.rs): no tools.
            body["tools"] = [Any]()
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = false
            body["include"] = [Any]()
        }
        return body
    }
}

public struct ResponsesResult: Sendable, Equatable {
    public var text: String
    public var model: String
    public var usage: AssistUsage?

    func validatedAssistResponse() throws -> AssistResponse {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistError.emptyResponse
        }
        return AssistResponse(text: text, model: model, usage: usage)
    }
}

/// Why a streamed model request failed, for every wire format in this module:
/// the Responses API, Chat Completions and Anthropic Messages.
public enum ResponsesError: Error, Equatable, Sendable {
    /// A non-200 status, with the body the server sent.
    case http(status: Int, headers: [String: String], body: String)
    /// An `error` or `response.failed` event inside a 200 stream.
    case stream(code: String?, message: String?)
    case transport(String)

    /// The parsed error body of an `.http` failure, when it is JSON.
    public var errorBody: ResponsesErrorBody? {
        guard case .http(_, _, let body) = self else { return nil }
        return ResponsesErrorBody(json: body)
    }
}

/// The fields of a provider's error body that change what the person is told.
///
/// The ChatGPT backend's usage-limit 429 looks like
/// `{"error":{"type":"usage_limit_reached","plan_type":"plus","resets_at":…,"resets_in_seconds":…}}`
/// (codex-rs parses the same fields); the public API's errors are
/// `{"error":{"message":…,"type":…,"code":…}}`; some backend errors are `{"detail":…}`.
/// Anthropic sends `{"type":"error","error":{"type":…,"message":…}}`, and Gemini's
/// OpenAI-compatible endpoint wraps its error object in a one-element array.
public struct ResponsesErrorBody: Sendable, Equatable {
    public var type: String?
    public var code: String?
    public var message: String?
    public var planType: String?
    public var resetsAt: Date?
    public var resetsInSeconds: TimeInterval?

    public init?(json: String) {
        guard let data = json.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] ?? (parsed as? [[String: Any]])?.first else { return nil }
        if let error = object["error"] as? [String: Any] {
            type = error["type"] as? String
            code = error["code"] as? String
            message = error["message"] as? String
            planType = error["plan_type"] as? String
            resetsAt = (error["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            resetsInSeconds = error["resets_in_seconds"] as? Double
        } else if let error = object["error"] as? String {
            code = error
            message = object["error_description"] as? String ?? object["message"] as? String
        } else if let detail = object["detail"] as? String {
            message = detail
        } else if let detail = object["detail"] as? [String: Any] {
            code = detail["code"] as? String
            message = detail["message"] as? String
        } else {
            return nil
        }
        code = code ?? object["code"] as? String
    }

    /// When the limit resets: the absolute time if given, else relative to `now`.
    public func resetDate(now: Date = .now) -> Date? {
        resetsAt ?? resetsInSeconds.map { now.addingTimeInterval($0) }
    }
}

/// Turns server-sent event lines into the final text.
///
/// OpenAI sends one `data:` line per event, so each is handled as it comes;
/// `event:` lines, comments and blank separators carry nothing needed here.
struct ResponsesStreamDecoder: StreamDecoder {
    let requestedModel: String
    private var text = ""
    private var doneText: String?

    init(requestedModel: String) {
        self.requestedModel = requestedModel
    }

    /// The result once the response has completed, else nil.
    mutating func consume(_ line: String) throws -> ResponsesResult? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
        case "response.output_text.done":
            doneText = (doneText ?? "") + (event["text"] as? String ?? "")
        case "response.completed", "response.incomplete":
            let response = event["response"] as? [String: Any] ?? [:]
            return ResponsesResult(
                text: finalText(response: response),
                model: response["model"] as? String ?? requestedModel,
                usage: Self.usage(response["usage"] as? [String: Any])
            )
        case "response.failed":
            let error = (event["response"] as? [String: Any])?["error"] as? [String: Any]
            throw ResponsesError.stream(code: error?["code"] as? String, message: error?["message"] as? String)
        case "error":
            let nested = event["error"] as? [String: Any]
            throw ResponsesError.stream(
                code: event["code"] as? String ?? nested?["code"] as? String ?? nested?["type"] as? String,
                message: event["message"] as? String ?? nested?["message"] as? String
            )
        default:
            break
        }
        return nil
    }

    /// The stream closed without a completion event: keep what arrived, if anything did.
    func finish() throws -> ResponsesResult {
        let result = doneText ?? text
        guard !result.isEmpty else { throw ResponsesError.transport("The response ended before any text arrived.") }
        return ResponsesResult(text: result, model: requestedModel, usage: nil)
    }

    private func finalText(response: [String: Any]) -> String {
        if !text.isEmpty { return text }
        if let doneText { return doneText }
        // No deltas: fall back to the output items of the completed response.
        let items = response["output"] as? [[String: Any]] ?? []
        return items
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private static func usage(_ usage: [String: Any]?) -> AssistUsage? {
        guard let usage, let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int else { return nil }
        return AssistUsage(inputTokens: input, outputTokens: output)
    }
}
