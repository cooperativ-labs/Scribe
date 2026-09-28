import Foundation

/// A model provider the person can bring their own API key for.
///
/// Every provider speaks one of three wire formats, so adding a provider that
/// offers an OpenAI-compatible endpoint is one more case here and nothing else:
/// OpenAI's own Responses API, Anthropic's Messages API, or Chat Completions,
/// which Google, OpenRouter, the Vercel AI Gateway, xAI, Groq, Mistral and
/// DeepSeek all serve. `custom` is any other Chat Completions server the person
/// names by URL: Ollama or LM Studio on this Mac, or a company gateway.
public enum AssistProvider: String, CaseIterable, Sendable, Identifiable {
    case openAI = "openai"
    case anthropic
    case gemini
    case openRouter = "openrouter"
    case vercelGateway = "vercel"
    case xAI = "xai"
    case groq
    case mistral
    case deepSeek = "deepseek"
    case custom

    public enum Wire: Sendable {
        /// `POST /responses`, as the ChatGPT route uses.
        case responses
        /// `POST /v1/messages`.
        case anthropicMessages
        /// `POST /chat/completions`.
        case chatCompletions
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .vercelGateway: "Vercel AI Gateway"
        case .xAI: "xAI"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .deepSeek: "DeepSeek"
        case .custom: "Custom endpoint"
        }
    }

    /// True for the provider whose server the person names by URL, so Settings
    /// asks for a base URL and the key may be empty.
    public var isCustom: Bool { self == .custom }

    /// Whether the assistant works without a key. Ollama and LM Studio take
    /// none; a gateway that wants one refuses the request and says so.
    public var keyIsOptional: Bool { isCustom }

    public var wire: Wire {
        switch self {
        case .openAI: .responses
        case .anthropic: .anthropicMessages
        default: .chatCompletions
        }
    }

    /// Where requests go. For `custom` this is Ollama's default address, shown
    /// as the placeholder; the person's own URL comes from Settings and is
    /// passed to `makeAssistant(baseURL:)`.
    public var baseURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .vercelGateway: URL(string: "https://ai-gateway.vercel.sh/v1")!
        case .xAI: URL(string: "https://api.x.ai/v1")!
        case .groq: URL(string: "https://api.groq.com/openai/v1")!
        case .mistral: URL(string: "https://api.mistral.ai/v1")!
        case .deepSeek: URL(string: "https://api.deepseek.com/v1")!
        case .custom: URL(string: "http://localhost:11434/v1")!
        }
    }

    /// Used until the person picks another from the provider's list. Empty
    /// for `custom`: the server's models are whatever it has loaded, so the
    /// first listed one is chosen once the connection is tested.
    public var defaultModel: String {
        switch self {
        case .openAI: OpenAIKeyAssistant.defaultModel
        case .anthropic: "claude-opus-5"
        case .gemini: "gemini-3.8-flash"
        // OpenRouter's own router, which picks a model per request.
        case .openRouter: "openrouter/auto"
        case .vercelGateway: "openai/gpt-5-mini"
        case .xAI: "grok-4"
        case .groq: "openai/gpt-oss-120b"
        case .mistral: "mistral-medium-latest"
        case .deepSeek: "deepseek-chat"
        case .custom: ""
        }
    }

    /// The Keychain service for this provider's key. OpenAI keeps the service
    /// it has always used, so a key saved before providers existed still works.
    public var keychainService: String {
        self == .openAI ? KeychainStore.openAIService : "co.cooperativ.scribe.\(rawValue)"
    }

    /// Shown in the empty key field.
    public var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-…"
        case .anthropic: "sk-ant-…"
        case .gemini: "AIza…"
        case .openRouter: "sk-or-…"
        case .xAI: "xai-…"
        case .groq: "gsk_…"
        case .custom: "API key (optional)"
        default: "API key"
        }
    }

    /// Where the person creates a key, nil for a server they run themselves.
    public var keysURL: URL? {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
        case .vercelGateway: URL(string: "https://vercel.com/ai-gateway")!
        case .xAI: URL(string: "https://console.x.ai")!
        case .groq: URL(string: "https://console.groq.com/keys")!
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .custom: nil
        }
    }

    /// True when a gateway that reaches many labs' models with one key.
    public var isGateway: Bool {
        self == .openRouter || self == .vercelGateway
    }

    /// Whether the provider accepts `stream_options.include_usage`, which asks
    /// for token counts in the last chunk of a Chat Completions stream.
    var sendsStreamUsageOption: Bool {
        switch self {
        case .gemini, .openRouter, .vercelGateway, .xAI, .groq, .deepSeek: true
        // Mistral reports usage in the last chunk unasked. An unknown server
        // may refuse a field it does not know, and usage is only a nicety.
        case .openAI, .anthropic, .mistral, .custom: false
        }
    }

    /// Headers that identify Scribe to a gateway's app rankings. Never secret.
    var attributionHeaders: [String: String] {
        self == .openRouter ? ["HTTP-Referer": "https://scribe.ovld.ai", "X-Title": "Scribe"] : [:]
    }

    /// The assistant that sends requests with this provider's key. `baseURL`
    /// is the person's own server for `custom`; the catalog's URL otherwise.
    public func makeAssistant(
        apiKey: String,
        model: String,
        systemPrompt: String? = nil,
        maxOutputTokens: Int? = nil,
        baseURL: URL? = nil,
        transport: HTTPTransport = URLSessionTransport()
    ) -> any APIKeyAssistant {
        switch wire {
        case .responses:
            OpenAIKeyAssistant(apiKey: apiKey, model: model, systemPrompt: systemPrompt, transport: transport)
        case .anthropicMessages:
            AnthropicAssistant(apiKey: apiKey, model: model, systemPrompt: systemPrompt, maxOutputTokens: maxOutputTokens, transport: transport)
        case .chatCompletions:
            ChatCompletionsAssistant(provider: self, apiKey: apiKey, model: model, systemPrompt: systemPrompt, baseURL: baseURL, transport: transport)
        }
    }

    /// The base URL a person typed for a custom endpoint, or nil when it is
    /// not one requests can go to: it must be https, or http on this Mac's
    /// loopback interface. A
    /// trailing slash is dropped, and the path is kept as typed (usually
    /// `/v1`), since gateways mount the API where they like.
    public static func customBaseURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              scheme == "https" || isLoopbackHost(host),
              components.query == nil, components.fragment == nil,
              let url = components.url
        else { return nil }
        return url
    }

    /// DNS names such as `machine.local` can resolve to another computer.
    /// Accept only literal loopback addresses and localhost for cleartext.
    private static func isLoopbackHost(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        if host == "[::1]" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) &&
            part.allSatisfy(\.isASCII) && Int(part).map { (0...255).contains($0) } == true
        }
    }
}

/// An assistant billed to the person's own key with one provider.
public protocol APIKeyAssistant: TextAssistant {
    var provider: AssistProvider { get }
    var model: String { get }
    /// Checks the key and returns the models the picker offers. Throws
    /// `AssistError.invalidAPIKey` when the provider refuses the key.
    func availableModels() async throws -> [AssistModel]
}

/// One entry in the Model picker.
public struct AssistModel: Sendable, Hashable, Codable, Identifiable {
    /// What the request sends, e.g. "gpt-6-luna".
    public var slug: String
    /// What the picker shows, e.g. "GPT-6 Luna (light)".
    public var displayName: String
    /// The most the model can write in one answer, when the provider says.
    public var maxOutputTokens: Int?

    public var id: String { slug }

    public init(slug: String, displayName: String, maxOutputTokens: Int? = nil) {
        self.slug = slug
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
    }
}

enum APIKeyErrors {
    /// A failed request with a provider's key, in the terms Settings shows.
    static func map(_ error: ResponsesError, provider: AssistProvider, model: String) -> AssistError {
        let name = provider.displayName
        switch error {
        case .http(let status, let headers, _):
            let body = error.errorBody
            switch status {
            case 401:
                return .invalidAPIKey(provider: name)
            // Google answers a bad key with 400 and xAI or Groq sometimes with 400 or 403.
            case 400 where isKeyError(body), 403 where isKeyError(body):
                return .invalidAPIKey(provider: name)
            case 429:
                return .rateLimited(provider: name, retryAfter: headers["retry-after"].flatMap(TimeInterval.init), message: body?.message)
            case 400 where isModelError(body), 404 where isModelError(body):
                return .modelUnavailable(model)
            default:
                return .server(provider: name, status: status, message: body?.message)
            }
        case .stream(let code, let message):
            if code == "model_not_found" { return .modelUnavailable(model) }
            return .server(provider: name, status: 200, message: message ?? code)
        case .transport(let message):
            return .network(message)
        }
    }

    static func isKeyError(_ body: ResponsesErrorBody?) -> Bool {
        guard let body else { return false }
        if body.type == "authentication_error" { return true }
        let text = "\(body.code ?? "") \(body.message ?? "")".lowercased()
        return text.contains("api key") || text.contains("api_key")
    }

    static func isModelError(_ body: ResponsesErrorBody?) -> Bool {
        guard let body else { return false }
        if body.code == "model_not_found" { return true }
        return body.message?.lowercased().contains("model") ?? false
    }

    /// Words that mark a listed model as unable to write text: audio, image,
    /// video, embedding, moderation and realtime variants.
    static let nonTextMarkers = [
        "audio", "image", "imagen", "realtime", "search", "transcribe", "tts", "whisper", "embed",
        "moderation", "guard", "veo", "live", "aqa", "dall-e", "sora", "ocr",
    ]

    static func isTextModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return !nonTextMarkers.contains(where: lowered.contains)
    }
}
