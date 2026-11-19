@testable import Assist
import XCTest

/// The fixtures cover Responses API event and error shapes.
final class ResponsesClientTests: XCTestCase {
    private let base = URL(string: "https://example.test/v1")!

    func testConcatenatesOutputTextDeltasAndReadsUsage() async throws {
        let sse = try Fixture.text("chatgpt-stream.sse")
        let transport = FakeTransport { _ in .init(status: 200, headers: ["Content-Type": "text/event-stream"], body: sse) }
        let client = ResponsesClient(baseURL: base, headers: ["Authorization": "Bearer t"], transport: transport)

        let result = try await client.respond(model: "gpt-6-luna", instructions: "system", input: "user")

        XCTAssertEqual(result.text, "Hi Sam,\n\nWe'll confirm pricing by Friday. Could you keep the sandbox open until validation ends?")
        XCTAssertEqual(result.model, "gpt-6-luna")
        XCTAssertEqual(result.usage, AssistUsage(inputTokens: 1204, outputTokens: 38))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["instructions"] as? String, "system")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(Set(body.keys), ["model", "instructions", "input", "store", "stream"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, "user")
    }

    func testFallsBackToTheCompletedOutputWhenNoDeltasArrive() async throws {
        let sse = try Fixture.text("completed-without-deltas.sse")
        let client = ResponsesClient(baseURL: base, headers: [:], transport: FakeTransport { _ in .init(status: 200, body: sse) })
        let result = try await client.respond(model: "gpt-5-mini", instructions: "s", input: "i")
        XCTAssertEqual(result.text, "Please send me the report by Monday.")
        XCTAssertEqual(result.model, "gpt-5-mini-2026-08-07")
        XCTAssertEqual(result.usage, AssistUsage(inputTokens: 212, outputTokens: 9))
    }

    func testFailedResponseEventThrowsItsError() async throws {
        let sse = try Fixture.text("response-failed.sse")
        let client = ResponsesClient(baseURL: base, headers: [:], transport: FakeTransport { _ in .init(status: 200, body: sse) })
        do {
            _ = try await client.respond(model: "m", instructions: "s", input: "i")
            XCTFail("expected an error")
        } catch let error as ResponsesError {
            XCTAssertEqual(error, .stream(code: "server_error", message: "The model produced invalid content."))
        }
    }

    func testStreamThatEndsEarlyKeepsWhatArrived() async throws {
        let sse = """
        data: {"type":"response.output_text.delta","delta":"Half"}
        data: {"type":"response.output_text.delta","delta":" an answer"}
        """
        let client = ResponsesClient(baseURL: base, headers: [:], transport: FakeTransport { _ in .init(status: 200, body: sse) })
        let result = try await client.respond(model: "m", instructions: "s", input: "i")
        XCTAssertEqual(result.text, "Half an answer")
        XCTAssertNil(result.usage)
    }

    func testEmptyStreamIsAnError() async throws {
        let client = ResponsesClient(baseURL: base, headers: [:], transport: FakeTransport { _ in .init(status: 200, body: "") })
        do {
            _ = try await client.respond(model: "m", instructions: "s", input: "i")
            XCTFail("expected an error")
        } catch let error as ResponsesError {
            guard case .transport = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testAPIKey429IsARateLimitWithTheServersMessage() throws {
        let body = try Fixture.text("api-429.json")
        let error = ResponsesError.http(status: 429, headers: ["retry-after": "1"], body: body)
        guard case .rateLimited("OpenAI", let retryAfter, let message) = OpenAIKeyAssistant.map(error, model: "gpt-5-mini") else {
            return XCTFail("expected a rate limit")
        }
        XCTAssertEqual(retryAfter, 1)
        XCTAssertTrue(message?.hasPrefix("Rate limit reached for gpt-5-mini") == true)
    }

    func testAPIKeyStatusMapping() {
        XCTAssertEqual(OpenAIKeyAssistant.map(.http(status: 401, headers: [:], body: ""), model: "m"), .invalidAPIKey(provider: "OpenAI"))
        XCTAssertEqual(
            OpenAIKeyAssistant.map(.http(status: 404, headers: [:], body: #"{"error":{"message":"The model `x` does not exist","code":"model_not_found"}}"#), model: "x"),
            .modelUnavailable("x")
        )
    }

    func testAPIKeyModelListKeepsTextModels() {
        let ids = ["gpt-5-mini", "gpt-4o-audio-preview", "whisper-1", "gpt-realtime", "gpt-6-luna", "gpt-image-1", "text-embedding-3-small"]
        XCTAssertEqual(OpenAIKeyAssistant.textModels(ids), ["gpt-5-mini", "gpt-6-luna"])
    }
}
