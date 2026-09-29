import Foundation
@testable import Assist
import XCTest

final class CodexAppServerTests: XCTestCase {
    func testManagedAccountAndModelList() async throws {
        let fixture = try StubAppServer()
        defer { fixture.remove() }
        let server = CodexAppServer(executableURL: fixture.url)

        let account = try await server.account()
        XCTAssertEqual(account, CodexAccount(email: "jake@example.com", planType: "plus"))
        let models = try await server.models()
        XCTAssertEqual(models, [AssistModel(slug: "gpt-6-sol", displayName: "GPT-6 Sol")])
    }

    func testManagedDeviceSignInReturnsCodeThenUsesCodexAccount() async throws {
        let fixture = try StubAppServer()
        defer { fixture.remove() }
        let server = CodexAppServer(executableURL: fixture.url)
        let codes = CodeCollector()

        let account = try await server.signIn { code in await codes.append(code) }
        XCTAssertEqual(account.email, "jake@example.com")
        let seen = await codes.values
        XCTAssertEqual(seen.map(\.userCode), ["ABCD-1234"])
        XCTAssertEqual(seen.first?.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
    }

    func testAgentTurnUsesEphemeralReadOnlyThreadAndReturnsFinalAnswer() async throws {
        let fixture = try StubAppServer()
        defer { fixture.remove() }
        let assistant = CodexAppServerAssistant(
            server: CodexAppServer(executableURL: fixture.url),
            model: "gpt-6-sol", systemPrompt: nil
        )

        let answer = try await assistant.respond(to: AssistRequest(instruction: "Find the latest Knowledgebase note"))
        XCTAssertEqual(answer.text, "The latest note is Project Atlas.")
        XCTAssertEqual(answer.model, "gpt-6-sol")
    }

    func testApprovalRequestStopsWithoutInsertingAReply() async throws {
        let fixture = try StubAppServer()
        defer { fixture.remove() }
        let server = CodexAppServer(executableURL: fixture.url)

        do {
            _ = try await server.respond(model: "gpt-6-sol", instructions: "Answer", input: "needs_approval")
            XCTFail("An approval request must stop the voice turn")
        } catch let error as CodexAppServerError {
            guard case .needsInteraction = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testConnectedToolCanContinueAfterThePersonApproves() async throws {
        let fixture = try StubAppServer()
        defer { fixture.remove() }
        let server = CodexAppServer(executableURL: fixture.url)
        let answer = try await server.respond(
            model: "gpt-6-sol", instructions: "Answer", input: "needs_approval",
            requestInput: { questions in
                guard questions.first?.question == "Read the linked note?" else { return nil }
                return ["approval": "Accept"]
            }
        )
        XCTAssertEqual(answer.text, "The latest note is Project Atlas.")
    }
}

private actor CodeCollector {
    private(set) var values: [CodexDeviceCode] = []
    func append(_ code: CodexDeviceCode) { values.append(code) }
}

/// An executable protocol peer, not a model mock: it checks the request's
/// sandbox and thread lifetime before emitting the same JSONL event shapes as
/// Codex App Server. No account, network, or Keychain is touched by the test.
private struct StubAppServer {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-codex-stub-\(UUID().uuidString)")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*)
              echo '{"id":1,"result":{"userAgent":"stub"}}' ;;
            *'"method":"account/login/start"'*)
              echo '{"id":2,"result":{"type":"chatgptDeviceCode","loginId":"login-1","verificationUrl":"https://auth.openai.com/codex/device","userCode":"ABCD-1234"}}'
              echo '{"method":"account/login/completed","params":{"loginId":"login-1","success":true,"error":null}}' ;;
            *'"method":"account/read"'*'"id":3'*|*'"id":3'*'"method":"account/read"'*)
              echo '{"id":3,"result":{"account":{"type":"chatgpt","email":"jake@example.com","planType":"plus"},"requiresOpenaiAuth":true}}' ;;
            *'"method":"account/read"'*)
              echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"jake@example.com","planType":"plus"},"requiresOpenaiAuth":true}}' ;;
            *'"method":"model/list"'*)
              echo '{"id":2,"result":{"data":[{"id":"gpt-6-sol","model":"gpt-6-sol","displayName":"GPT-6 Sol"}],"nextCursor":null}}' ;;
            *'"method":"thread/start"'*)
              case "$line" in
                *'"ephemeral":true'*'"read-only"'*|*'"read-only"'*'"ephemeral":true'*)
                  echo '{"id":3,"result":{"thread":{"id":"thr-test"}}}' ;;
                *) echo '{"id":3,"error":{"message":"Thread was not ephemeral and read-only"}}' ;;
              esac ;;
            *'"method":"turn/start"'*)
              echo '{"id":4,"result":{"turn":{"id":"turn-test","status":"inProgress"}}}'
              case "$line" in
                *needs_approval*)
                  echo '{"id":"approval-request","method":"item/tool/requestUserInput","params":{"threadId":"thr-test","turnId":"turn-test","itemId":"item-test","isBlocking":true,"autoResolutionMs":null,"questions":[{"id":"approval","header":"Access","question":"Read the linked note?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Read it"},{"label":"Decline","description":"Skip it"}]}]}}' ;;
                *)
                  echo '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","item":{"type":"mcpToolCall","id":"tool-1"}}}'
                  echo '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","item":{"type":"agentMessage","id":"answer-1","phase":"final_answer","text":"The latest note is Project Atlas."}}}'
                  echo '{"method":"turn/completed","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"completed"}}}' ;;
              esac ;;
            *'"id":"approval-request"'*)
              echo '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","item":{"type":"agentMessage","id":"answer-1","phase":"final_answer","text":"The latest note is Project Atlas."}}}'
              echo '{"method":"turn/completed","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"completed"}}}' ;;
          esac
        done
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
