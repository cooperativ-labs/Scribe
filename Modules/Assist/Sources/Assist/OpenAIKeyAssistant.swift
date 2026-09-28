import Foundation

/// The fully supported route: the person's own OpenAI API key against
/// `api.openai.com`, billed to their Platform account at API rates.
public struct OpenAIKeyAssistant: APIKeyAssistant {
    public static let baseURL = URL(string: "https://api.openai.com/v1")!
    /// Where the key is kept in the Keychain.
    public static let keychainAccount = "api-key"
    /// A model every API account has, used until the person picks another.
    public static let defaultModel = "gpt-5-mini"

    public let displayName = "OpenAI"
    public let provider = AssistProvider.openAI
    public var model: String
    public var systemPrompt: String?
    private let apiKey: String
    private let transport: HTTPTransport

    public init(apiKey: String, model: String, systemPrompt: String? = nil, transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.transport = transport
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        let client = ResponsesClient(baseURL: Self.baseURL, headers: ["Authorization": "Bearer \(apiKey)"], transport: transport)
        do {
            let result = try await client.respond(
                model: model,
                instructions: AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName),
                input: AssistPrompt.input(for: request)
            )
            return try result.validatedAssistResponse()
        } catch let error as ResponsesError {
            throw Self.map(error, model: model)
        }
    }

    /// Checks the key by listing models: the result the Test button shows, and
    /// the list the Model picker offers.
    public func availableModels() async throws -> [AssistModel] {
        var request = URLRequest(url: Self.baseURL.appending(path: "models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        do {
            let object = try await transport.json(request) as? [String: Any]
            let ids = (object?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return Self.textModels(ids).map { AssistModel(slug: $0, displayName: $0) }
        } catch let error as ResponsesError {
            throw Self.map(error, model: model)
        }
    }

    /// The chat-capable `gpt-*` models, leaving out audio, image, realtime,
    /// search and transcription variants, which the Responses call cannot use.
    static func textModels(_ ids: [String]) -> [String] {
        let excluded = ["audio", "image", "realtime", "search", "transcribe", "tts", "embedding", "moderation", "instruct"]
        return ids
            .filter { $0.hasPrefix("gpt-") && !excluded.contains(where: $0.contains) }
            .sorted()
    }

    static func map(_ error: ResponsesError, model: String) -> AssistError {
        APIKeyErrors.map(error, provider: .openAI, model: model)
    }
}
