import Foundation

/// The person's own key with a provider that serves OpenAI's Chat Completions
/// format: Google Gemini, OpenRouter, the Vercel AI Gateway, xAI, Groq,
/// Mistral and DeepSeek, or any server the person names by URL (Ollama, LM
/// Studio, a company gateway). They differ only in base URL, default model and
/// a few headers, which `AssistProvider` holds.
public struct ChatCompletionsAssistant: APIKeyAssistant {
    public let provider: AssistProvider
    public var model: String
    public var systemPrompt: String?
    /// Where `chat/completions` and `models` are appended.
    public let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport

    /// The provider's name, or the server's host for a custom endpoint, so
    /// the indicator says where the request went.
    public var displayName: String {
        provider.isCustom ? baseURL.host() ?? provider.displayName : provider.displayName
    }

    public init(
        provider: AssistProvider,
        apiKey: String,
        model: String,
        systemPrompt: String? = nil,
        baseURL: URL? = nil,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.baseURL = baseURL ?? provider.baseURL
        self.transport = transport
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        try validateCustomBaseURL()
        var urlRequest = authorized(baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(
            instructions: AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName),
            input: AssistPrompt.input(for: request)
        ))
        do {
            let result = try await transport.stream(urlRequest, decoder: ChatCompletionsStreamDecoder(requestedModel: model))
            return try result.validatedAssistResponse()
        } catch let error as ResponsesError {
            throw APIKeyErrors.map(error, provider: provider, model: model)
        }
    }

    public func availableModels() async throws -> [AssistModel] {
        try validateCustomBaseURL()
        do {
            // OpenRouter lists its models without a key, so the key is checked on its own first.
            if provider == .openRouter {
                var check = authorized(baseURL.appending(path: "key"))
                check.timeoutInterval = 20
                _ = try await transport.json(check)
            }
            var request = authorized(baseURL.appending(path: "models"))
            request.timeoutInterval = 20
            let object = try await transport.json(request) as? [String: Any]
            return Self.textModels(object?["data"] as? [[String: Any]] ?? [], provider: provider)
        } catch let error as ResponsesError {
            throw APIKeyErrors.map(error, provider: provider, model: model)
        }
    }

    /// Also check direct callers, which can bypass Settings and its URL parser.
    private func validateCustomBaseURL() throws {
        if provider.isCustom && AssistProvider.customBaseURL(baseURL.absoluteString) == nil {
            throw AssistError.network("Custom endpoints must use HTTPS, or HTTP to localhost or a loopback IP address.")
        }
    }

    func body(instructions: String, input: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": input],
            ],
            "stream": true,
        ]
        if provider.sendsStreamUsageOption {
            body["stream_options"] = ["include_usage": true]
        }
        return body
    }

    /// A local server that takes no key is sent no Authorization header at all;
    /// some refuse a bearer token they cannot check.
    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in provider.attributionHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// The Vercel AI Gateway types its entries; Mistral's "base" and "fine-tuned" are both chat models.
    static let nonTextTypes: Set<String> = ["embedding", "image", "video", "audio", "transcription", "speech", "moderation", "rerank"]

    /// The listed models that write text, by display name.
    static func textModels(_ entries: [[String: Any]], provider: AssistProvider) -> [AssistModel] {
        entries.compactMap { entry -> AssistModel? in
            guard var slug = entry["id"] as? String else { return nil }
            // Google lists "models/gemini-…" but takes the bare name in requests.
            if slug.hasPrefix("models/") { slug.removeFirst("models/".count) }
            if let type = entry["type"] as? String, nonTextTypes.contains(type) { return nil }
            if let outputs = (entry["architecture"] as? [String: Any])?["output_modalities"] as? [String] {
                guard outputs.contains("text") else { return nil }
            } else if !APIKeyErrors.isTextModel(slug) {
                return nil
            }
            if provider == .gemini, !slug.hasPrefix("gemini") { return nil }
            let name = (entry["name"] as? String).flatMap { $0.isEmpty || $0 == entry["id"] as? String ? nil : $0 } ?? slug
            return AssistModel(slug: slug, displayName: name)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// Concatenates `choices[0].delta.content` until `[DONE]`, keeping the usage
/// the last chunk carries.
struct ChatCompletionsStreamDecoder: StreamDecoder {
    let requestedModel: String
    private var text = ""
    private var model: String?
    private var usage: AssistUsage?

    init(requestedModel: String) {
        self.requestedModel = requestedModel
    }

    mutating func consume(_ line: String) throws -> ResponsesResult? {
        if line.trimmingCharacters(in: .whitespaces) == "data: [DONE]" {
            return result
        }
        guard let event = eventPayload(line) else { return nil }
        // OpenRouter reports a failure after the stream has started as an error chunk.
        if let error = event["error"] as? [String: Any] {
            let code = error["code"].map { String(describing: $0) }
            throw ResponsesError.stream(code: code, message: error["message"] as? String)
        }
        if let name = event["model"] as? String, !name.isEmpty { model = name }
        let choice = (event["choices"] as? [[String: Any]])?.first
        if let content = (choice?["delta"] as? [String: Any])?["content"] as? String {
            text += content
        }
        if choice?["finish_reason"] as? String == "error" {
            throw ResponsesError.stream(code: nil, message: nil)
        }
        if let counts = event["usage"] as? [String: Any],
           let input = counts["prompt_tokens"] as? Int, let output = counts["completion_tokens"] as? Int {
            usage = AssistUsage(inputTokens: input, outputTokens: output)
        }
        return nil
    }

    /// Some servers close the stream without `[DONE]`: keep what arrived, if anything did.
    func finish() throws -> ResponsesResult {
        guard !text.isEmpty else { throw ResponsesError.transport("The response ended before any text arrived.") }
        return result
    }

    private var result: ResponsesResult {
        ResponsesResult(text: text, model: model ?? requestedModel, usage: usage)
    }
}
