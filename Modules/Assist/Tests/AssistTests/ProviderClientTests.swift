@testable import Assist
import XCTest

/// Chat Completions and Anthropic Messages, and the provider catalog that picks between them.
final class ProviderClientTests: XCTestCase {
    private let request = AssistRequest(instruction: "Reply yes", selectedText: "Can you make Friday?", applicationName: "Mail", locale: "en_US")

    func testEveryProviderHasADistinctKeychainServiceAndOpenAIKeepsItsOwn() {
        XCTAssertEqual(AssistProvider.openAI.keychainService, KeychainStore.openAIService)
        XCTAssertEqual(Set(AssistProvider.allCases.map(\.keychainService)).count, AssistProvider.allCases.count)
        XCTAssertEqual(AssistProvider.anthropic.wire, .anthropicMessages)
        XCTAssertEqual(AssistProvider.gemini.wire, .chatCompletions)
        XCTAssertTrue(AssistProvider.openAI.makeAssistant(apiKey: "k", model: "m") is OpenAIKeyAssistant)
        XCTAssertTrue(AssistProvider.anthropic.makeAssistant(apiKey: "k", model: "m") is AnthropicAssistant)
        XCTAssertTrue(AssistProvider.openRouter.makeAssistant(apiKey: "k", model: "m") is ChatCompletionsAssistant)
    }

    func testChatCompletionsStreamsTextAndUsage() async throws {
        let sse = try Fixture.text("chat-completions-stream.sse")
        let transport = FakeTransport { _ in .init(status: 200, body: sse) }
        let assistant = ChatCompletionsAssistant(provider: .openRouter, apiKey: "sk-or-1", model: "anthropic/claude-opus-5", transport: transport)

        let response = try await assistant.respond(to: request)

        XCTAssertEqual(response.text, "Thanks, see you Friday.")
        XCTAssertEqual(response.model, "anthropic/claude-opus-5")
        XCTAssertEqual(response.usage, AssistUsage(inputTokens: 812, outputTokens: 9))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Title"), "Scribe")
        let body = try XCTUnwrap(sent.jsonBody)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String)?.contains("Mail") == true)
        XCTAssertTrue((messages[1]["content"] as? String)?.contains("<selected_text>") == true)
    }

    func testACustomEndpointUsesTheTypedURLAndSendsNoHeaderWithoutAKey() async throws {
        let sse = try Fixture.text("chat-completions-stream.sse")
        let transport = FakeTransport { _ in .init(status: 200, body: sse) }
        let base = try XCTUnwrap(AssistProvider.customBaseURL("http://localhost:11434/v1/"))
        let assistant = try XCTUnwrap(AssistProvider.custom.makeAssistant(apiKey: "", model: "llama3.2", baseURL: base, transport: transport) as? ChatCompletionsAssistant)

        let response = try await assistant.respond(to: request)

        XCTAssertEqual(response.text, "Thanks, see you Friday.")
        XCTAssertEqual(assistant.displayName, "localhost")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Title"))
        let body = try XCTUnwrap(sent.jsonBody)
        XCTAssertEqual(body["model"] as? String, "llama3.2")
        XCTAssertNil(body["stream_options"])

        // A gateway that wants a key gets it the usual way.
        let keyed = ChatCompletionsAssistant(provider: .custom, apiKey: "gw-1", model: "m", baseURL: base, transport: transport)
        _ = try await keyed.respond(to: request)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer gw-1")
    }

    func testACustomEndpointListsWhateverTheServerHasLoaded() async throws {
        let transport = FakeTransport { _ in
            .init(status: 200, body: #"{"object":"list","data":[{"id":"llama3.2:latest","object":"model","owned_by":"library"},{"id":"nomic-embed-text:latest","object":"model","owned_by":"library"}]}"#)
        }
        let base = try XCTUnwrap(AssistProvider.customBaseURL("http://127.0.0.2:1234/v1"))
        let models = try await ChatCompletionsAssistant(provider: .custom, apiKey: "", model: "", baseURL: base, transport: transport).availableModels()
        XCTAssertEqual(models.map(\.slug), ["llama3.2:latest"])
        XCTAssertEqual(transport.requests.map(\.url?.absoluteString), ["http://127.0.0.2:1234/v1/models"])
    }

    func testCustomBaseURLsAreCheckedAndTidied() {
        XCTAssertEqual(AssistProvider.customBaseURL(" http://localhost:11434/v1/ ")?.absoluteString, "http://localhost:11434/v1")
        XCTAssertEqual(AssistProvider.customBaseURL("https://ai.example.com")?.absoluteString, "https://ai.example.com")
        XCTAssertEqual(AssistProvider.customBaseURL("HTTP://127.0.0.1:8080/openai/v1")?.absoluteString, "HTTP://127.0.0.1:8080/openai/v1")
        XCTAssertNotNil(AssistProvider.customBaseURL("http://[::1]:8080/v1"))
        for bad in ["", "localhost:11434", "ftp://host/v1", "http://", "http:///v1", "http://host/v1?key=1", "not a url", "http://lmstudio.local:1234/v1", "http://192.168.1.4/v1", "http://localhost.example.com/v1", "http://user:pass@localhost/v1"] {
            XCTAssertNil(AssistProvider.customBaseURL(bad), bad)
        }
        XCTAssertTrue(AssistProvider.custom.keyIsOptional)
        XCTAssertNil(AssistProvider.custom.keysURL)
        XCTAssertEqual(AssistProvider.custom.wire, .chatCompletions)
        XCTAssertTrue(AssistProvider.custom.defaultModel.isEmpty)
        XCTAssertFalse(AssistProvider.allCases.filter { !$0.isCustom }.contains { $0.keyIsOptional || $0.keysURL == nil || $0.defaultModel.isEmpty })
    }

    func testDirectCustomClientRejectsRemoteHTTPBeforeSendingKeyOrText() async throws {
        let transport = FakeTransport { _ in .init(status: 200, body: "") }
        let assistant = ChatCompletionsAssistant(
            provider: .custom, apiKey: "secret", model: "m",
            baseURL: try XCTUnwrap(URL(string: "http://gateway.local/v1")), transport: transport
        )
        do {
            _ = try await assistant.respond(to: request)
            XCTFail("expected the cleartext endpoint to be rejected")
        } catch let error as AssistError {
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }
        do {
            _ = try await assistant.availableModels()
            XCTFail("expected the cleartext endpoint to be rejected")
        } catch let error as AssistError {
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRedirectPolicyBlocksCleartextRemoteDestinations() throws {
        let policy = AssistantRedirectPolicy()
        let session = URLSession.shared
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "http://localhost:11434/v1/models")))
        func follows(_ origin: String, _ destination: String) throws -> Bool {
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(URL(string: origin)), statusCode: 302,
                httpVersion: nil, headerFields: nil
            ))
            let next = URLRequest(url: try XCTUnwrap(URL(string: destination)))
            var followed = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next) {
                followed = $0 != nil
            }
            return followed
        }
        XCTAssertFalse(try follows("http://localhost:11434/v1/models", "http://gateway.local/v1/models"))
        XCTAssertFalse(try follows("https://gateway.example/v1/models", "http://localhost:11434/v1/models"))
        XCTAssertTrue(try follows("http://localhost:11434/v1/models", "http://127.0.0.2:8080/v1/models"))
        XCTAssertTrue(try follows("https://gateway.example/v1/models", "https://gateway.example/v2/models"))
    }

    func testMistralIsNotSentTheUsageOption() {
        let assistant = ChatCompletionsAssistant(provider: .mistral, apiKey: "k", model: "m", transport: FakeTransport { _ in .init(status: 200, body: "") })
        XCTAssertNil(assistant.body(instructions: "s", input: "i")["stream_options"])
    }

    func testAnErrorChunkMidStreamFails() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Tha"}}]}

        data: {"error":{"code":502,"message":"Provider returned error"}}
        """
        let assistant = ChatCompletionsAssistant(provider: .openRouter, apiKey: "k", model: "m", transport: FakeTransport { _ in .init(status: 200, body: sse) })
        do {
            _ = try await assistant.respond(to: request)
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .server(provider: "OpenRouter", status: 200, message: "Provider returned error"))
        }
    }

    func testGeminiBadKeyIsAnInvalidKey() {
        let body = #"[{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}]"#
        XCTAssertEqual(APIKeyErrors.map(.http(status: 400, headers: [:], body: body), provider: .gemini, model: "m"), .invalidAPIKey(provider: "Google Gemini"))
    }

    func testAnthropicErrorsMap() {
        let auth = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertEqual(APIKeyErrors.map(.http(status: 401, headers: [:], body: auth), provider: .anthropic, model: "m"), .invalidAPIKey(provider: "Anthropic"))
        let missing = #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-x"}}"#
        XCTAssertEqual(APIKeyErrors.map(.http(status: 404, headers: [:], body: missing), provider: .anthropic, model: "claude-x"), .modelUnavailable("claude-x"))
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(APIKeyErrors.map(.http(status: 529, headers: [:], body: overloaded), provider: .anthropic, model: "m"), .server(provider: "Anthropic", status: 529, message: "Overloaded"))
    }

    func testOpenRouterChecksTheKeyBeforeListingModels() async throws {
        let transport = FakeTransport { request in
            switch request.url?.path {
            case "/api/v1/key": .init(status: 200, body: #"{"data":{"label":"sk-or-…"}}"#)
            default: .init(status: 200, body: """
                {"data":[
                  {"id":"openai/gpt-image-2","name":"OpenAI: GPT Image 2","architecture":{"output_modalities":["image"]}},
                  {"id":"anthropic/claude-opus-5","name":"Anthropic: Claude Opus 5","architecture":{"output_modalities":["text"]}},
                  {"id":"meta-llama/llama-4-maverick-instruct","name":"Meta: Llama 4 Maverick","architecture":{"output_modalities":["text"]}}
                ]}
                """)
            }
        }
        let models = try await ChatCompletionsAssistant(provider: .openRouter, apiKey: "k", model: "m", transport: transport).availableModels()
        XCTAssertEqual(models.map(\.slug), ["anthropic/claude-opus-5", "meta-llama/llama-4-maverick-instruct"])
        XCTAssertEqual(models.first?.displayName, "Anthropic: Claude Opus 5")
        XCTAssertEqual(transport.requests.map(\.url?.path), ["/api/v1/key", "/api/v1/models"])

        let refused = FakeTransport { _ in .init(status: 401, body: #"{"error":{"message":"Missing Authentication header","code":401}}"#) }
        do {
            _ = try await ChatCompletionsAssistant(provider: .openRouter, apiKey: "bad", model: "m", transport: refused).availableModels()
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .invalidAPIKey(provider: "OpenRouter"))
        }
    }

    func testGeminiModelListDropsThePrefixAndNonTextModels() {
        let entries: [[String: Any]] = [
            ["id": "models/gemini-3.8-flash", "object": "model"],
            ["id": "models/gemini-embedding-001", "object": "model"],
            ["id": "models/imagen-4.0-generate-001", "object": "model"],
            ["id": "models/gemini-2.5-flash-preview-tts", "object": "model"],
        ]
        XCTAssertEqual(ChatCompletionsAssistant.textModels(entries, provider: .gemini).map(\.slug), ["gemini-3.8-flash"])
    }

    func testMistralAndGatewayModelTypes() {
        let mistral: [[String: Any]] = [["id": "mistral-medium-latest", "type": "base"], ["id": "mistral-embed", "type": "base"]]
        XCTAssertEqual(ChatCompletionsAssistant.textModels(mistral, provider: .mistral).map(\.slug), ["mistral-medium-latest"])
        let gateway: [[String: Any]] = [["id": "openai/gpt-5-mini", "type": "language", "name": "GPT-5 mini"], ["id": "openai/text-embedding-3-small", "type": "embedding"]]
        XCTAssertEqual(ChatCompletionsAssistant.textModels(gateway, provider: .vercelGateway).map(\.displayName), ["GPT-5 mini"])
    }

    func testAnthropicStreamsTextSkippingThinking() async throws {
        let sse = try Fixture.text("anthropic-stream.sse")
        let transport = FakeTransport { _ in .init(status: 200, body: sse) }
        let assistant = AnthropicAssistant(apiKey: "sk-ant-1", model: "claude-opus-5", systemPrompt: "Be brief in {application}.", maxOutputTokens: 128_000, transport: transport)

        let response = try await assistant.respond(to: request)

        XCTAssertEqual(response.text, "Thanks, see you Friday.")
        XCTAssertEqual(response.model, "claude-opus-5")
        XCTAssertEqual(response.usage, AssistUsage(inputTokens: 800, outputTokens: 42))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-ant-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(sent.jsonBody)
        XCTAssertEqual(body["system"] as? String, "Be brief in Mail.")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicAssistant.defaultMaxOutputTokens)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.first?["role"] as? String, "user")
    }

    func testAnthropicAsksNoMoreThanTheModelAllows() {
        let assistant = AnthropicAssistant(apiKey: "k", model: "claude-3-haiku", maxOutputTokens: 4_096, transport: FakeTransport { _ in .init(status: 200, body: "") })
        XCTAssertEqual(assistant.body(instructions: "s", input: "i")["max_tokens"] as? Int, 4_096)
    }

    func testAnthropicModelListCarriesNamesAndLimits() async throws {
        let transport = FakeTransport { _ in
            .init(status: 200, body: #"{"data":[{"type":"model","id":"claude-opus-5","display_name":"Claude Opus 5","max_tokens":128000}],"has_more":false}"#)
        }
        let models = try await AnthropicAssistant(apiKey: "k", model: "m", transport: transport).availableModels()
        XCTAssertEqual(models, [AssistModel(slug: "claude-opus-5", displayName: "Claude Opus 5", maxOutputTokens: 128_000)])
        XCTAssertEqual(transport.requests.first?.url?.query, "limit=1000")
    }

    func testAnthropicStreamErrorEvent() async throws {
        let sse = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        let assistant = AnthropicAssistant(apiKey: "k", model: "m", transport: FakeTransport { _ in .init(status: 200, body: sse) })
        do {
            _ = try await assistant.respond(to: request)
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .server(provider: "Anthropic", status: 200, message: "Overloaded"))
        }
    }

    func testTrimmingCutsTheScreenFirstThenCopiedThenSelected() {
        let full = AssistRequest(
            instruction: "Summarise",
            selectedText: "SSSS",
            copiedText: "CCCC",
            screenText: [WindowText(title: "A", isFocused: true, text: "AAAA"), WindowText(title: "B", isFocused: false, text: "BBBB")]
        )
        XCTAssertEqual(full.trimmed(toCharacters: 16), full)

        let screenCut = full.trimmed(toCharacters: 10)
        XCTAssertTrue(screenCut.truncated)
        XCTAssertEqual(screenCut.screenText.map(\.text), ["AA"])
        XCTAssertEqual(screenCut.copiedText, "CCCC")

        let copiedCut = full.trimmed(toCharacters: 6)
        XCTAssertEqual(copiedCut.screenText, [])
        XCTAssertEqual(copiedCut.copiedText, "CC")
        XCTAssertEqual(copiedCut.selectedText, "SSSS")

        let bare = full.trimmed(toCharacters: 0)
        XCTAssertEqual(bare.selectedText, "")
        XCTAssertEqual(bare.instruction, "Summarise")
    }
}
