import Foundation

/// The person's own Anthropic API key against the Messages API, streamed.
public struct AnthropicAssistant: APIKeyAssistant {
    public static let apiVersion = "2023-06-01"
    /// Room for a long draft plus the model's thinking. Kept well below the
    /// models' own limits because the answer is text inserted into a field,
    /// and a smaller ceiling is gentler on low-tier output rate limits.
    public static let defaultMaxOutputTokens = 16_000

    public let displayName = "Anthropic"
    public let provider = AssistProvider.anthropic
    public var model: String
    public var systemPrompt: String?
    /// The chosen model's own limit, when the model list said; the request asks
    /// for the smaller of this and `defaultMaxOutputTokens`.
    public var maxOutputTokens: Int?
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, model: String, systemPrompt: String? = nil, maxOutputTokens: Int? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxOutputTokens = maxOutputTokens
        self.transport = transport
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        var urlRequest = authorized(provider.baseURL.appending(path: "messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(
            instructions: AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName),
            input: AssistPrompt.input(for: request)
        ))
        do {
            let result = try await transport.stream(urlRequest, decoder: AnthropicStreamDecoder(requestedModel: model))
            return try result.validatedAssistResponse()
        } catch let error as ResponsesError {
            throw APIKeyErrors.map(error, provider: provider, model: model)
        }
    }

    /// Lists the key's models, which also proves the key works.
    public func availableModels() async throws -> [AssistModel] {
        var components = URLComponents(url: provider.baseURL.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        var request = authorized(components.url!)
        request.timeoutInterval = 20
        do {
            let object = try await transport.json(request) as? [String: Any]
            return (object?["data"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return AssistModel(slug: id, displayName: entry["display_name"] as? String ?? id, maxOutputTokens: entry["max_tokens"] as? Int)
            }
        } catch let error as ResponsesError {
            throw APIKeyErrors.map(error, provider: provider, model: model)
        }
    }

    func body(instructions: String, input: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": min(maxOutputTokens ?? Self.defaultMaxOutputTokens, Self.defaultMaxOutputTokens),
            "system": instructions,
            "messages": [["role": "user", "content": input]],
            "stream": true,
        ]
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }
}

/// Reads the Messages stream: the model and input tokens from `message_start`,
/// the text from `text_delta`s, the output tokens from `message_delta`, and
/// the end from `message_stop`. Thinking blocks are skipped.
struct AnthropicStreamDecoder: StreamDecoder {
    let requestedModel: String
    private var text = ""
    private var model: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    init(requestedModel: String) {
        self.requestedModel = requestedModel
    }

    mutating func consume(_ line: String) throws -> ResponsesResult? {
        guard let event = eventPayload(line) else { return nil }
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            model = message?["model"] as? String
            let usage = message?["usage"] as? [String: Any]
            inputTokens = Self.inputTokens(usage)
            outputTokens = usage?["output_tokens"] as? Int
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta" {
                text += delta?["text"] as? String ?? ""
            }
        case "message_delta":
            if let output = (event["usage"] as? [String: Any])?["output_tokens"] as? Int {
                outputTokens = output
            }
        case "message_stop":
            return result
        case "error":
            let error = event["error"] as? [String: Any]
            throw ResponsesError.stream(code: error?["type"] as? String, message: error?["message"] as? String)
        default:
            break
        }
        return nil
    }

    func finish() throws -> ResponsesResult {
        guard !text.isEmpty else { throw ResponsesError.transport("The response ended before any text arrived.") }
        return result
    }

    private var result: ResponsesResult {
        let usage = inputTokens.flatMap { input in outputTokens.map { AssistUsage(inputTokens: input, outputTokens: $0) } }
        return ResponsesResult(text: text, model: model ?? requestedModel, usage: usage)
    }

    /// Cached tokens are reported apart from the uncached ones; the indicator shows them together.
    private static func inputTokens(_ usage: [String: Any]?) -> Int? {
        guard let usage, let input = usage["input_tokens"] as? Int else { return nil }
        let cached = (usage["cache_read_input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0)
        return input + cached
    }
}
