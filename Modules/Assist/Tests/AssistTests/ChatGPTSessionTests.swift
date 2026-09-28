@testable import Assist
import XCTest

final class ChatGPTSessionTests: XCTestCase {
    private let clock = TestClock()

    private func session(store: SecretStore, transport: FakeTransport, sleeps: SleepLog = SleepLog()) -> ChatGPTSession {
        let clock = clock
        return ChatGPTSession(
            store: store,
            transport: transport,
            now: { clock.now },
            sleep: { seconds in
                sleeps.record(seconds)
                clock.advance(seconds)
            }
        )
    }

    // MARK: Device flow

    func testDeviceFlowPollsAtTheServerIntervalThenExchangesAndStores() async throws {
        let store = InMemorySecretStore()
        let polls = Counter()
        let idToken = TestJWT.idToken(accountID: "acct_9", plan: "pro", email: "me@example.com")
        let transport = FakeTransport { request in
            switch request.url!.path {
            case "/api/accounts/deviceauth/usercode":
                return .init(status: 200, body: #"{"device_auth_id":"dev_1","user_code":"ABCD-1234","interval":"7"}"#)
            case "/api/accounts/deviceauth/token":
                return polls.increment() < 3
                    ? .init(status: 403, body: #"{"error":"authorization_pending"}"#)
                    : .init(status: 200, body: #"{"authorization_code":"code_1","code_challenge":"ch","code_verifier":"ver_1"}"#)
            case "/oauth/token":
                return .init(status: 200, body: """
                {"id_token":"\(idToken)","access_token":"\(TestJWT.accessToken(expiresAt: Date(timeIntervalSince1970: 1_790_003_600)))","refresh_token":"rt_1"}
                """)
            default:
                return .init(status: 500, body: "")
            }
        }
        let sleeps = SleepLog()
        let session = session(store: store, transport: transport, sleeps: sleeps)

        let pending = try await session.beginDeviceSignIn()
        XCTAssertEqual(pending.userCode, "ABCD-1234")
        XCTAssertEqual(pending.verificationURL, ChatGPTEndpoints.verificationURL)
        XCTAssertEqual(pending.expiresAt, clock.now.addingTimeInterval(15 * 60))
        let usercode = try XCTUnwrap(transport.requests(to: "/deviceauth/usercode").first)
        XCTAssertEqual(usercode.jsonBody?["client_id"] as? String, ChatGPTEndpoints.clientID)

        let account = try await session.completeDeviceSignIn(pending)
        XCTAssertEqual(account, ChatGPTAccount(accountID: "acct_9", planType: "pro", email: "me@example.com"))
        XCTAssertEqual(account.planName, "Pro")
        XCTAssertEqual(sleeps.values, [7, 7])

        let poll = try XCTUnwrap(transport.requests(to: "/deviceauth/token").first)
        XCTAssertEqual(poll.jsonBody?["device_auth_id"] as? String, "dev_1")
        XCTAssertEqual(poll.jsonBody?["user_code"] as? String, "ABCD-1234")

        let exchange = try XCTUnwrap(transport.requests(to: "/oauth/token").first)
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(exchange.formBody, [
            "grant_type": "authorization_code",
            "client_id": ChatGPTEndpoints.clientID,
            "code": "code_1",
            "redirect_uri": "https://auth.openai.com/deviceauth/callback",
            "code_verifier": "ver_1",
        ])

        let stored = try XCTUnwrap(try store.read(ChatGPTSession.tokensAccount))
        let tokens = try JSONDecoder().decode(StoredTokens.self, from: stored)
        XCTAssertEqual(tokens.refreshToken, "rt_1")
        XCTAssertEqual(tokens.accountID, "acct_9")
        let current = await session.account()
        XCTAssertEqual(current?.accountID, "acct_9")
    }

    func testDeviceFlowTimesOutAfterFifteenMinutes() async throws {
        let transport = FakeTransport { request in
            request.url!.path.hasSuffix("usercode")
                ? .init(status: 200, body: #"{"device_auth_id":"d","user_code":"C","interval":60}"#)
                : .init(status: 404, body: "")
        }
        let session = session(store: InMemorySecretStore(), transport: transport)
        let pending = try await session.beginDeviceSignIn()
        do {
            _ = try await session.completeDeviceSignIn(pending)
            XCTFail("expected a timeout")
        } catch let error as ChatGPTSignInError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertEqual(transport.requests(to: "/deviceauth/token").count, 15)
    }

    func testDeniedSignInStopsPolling() async throws {
        let transport = FakeTransport { request in
            request.url!.path.hasSuffix("usercode")
                ? .init(status: 200, body: #"{"device_auth_id":"d","user_code":"C","interval":5}"#)
                : .init(status: 400, body: #"{"error":{"message":"The code was declined."}}"#)
        }
        let session = session(store: InMemorySecretStore(), transport: transport)
        let pending = try await session.beginDeviceSignIn()
        do {
            _ = try await session.completeDeviceSignIn(pending)
            XCTFail("expected a denial")
        } catch let error as ChatGPTSignInError {
            XCTAssertEqual(error, .denied("The code was declined."))
        }
    }

    // MARK: Refresh

    func testFreshTokensAreUsedWithoutRefreshing() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        let transport = FakeTransport { _ in XCTFail("no request expected"); return .init(status: 500, body: "") }
        let credentials = try await session(store: store, transport: transport).credentials()
        XCTAssertEqual(credentials.accountID, "acct_123")
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testTheKeychainIsReadOncePerLaunch() async throws {
        let store = CountingStore(try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now))
        let transport = FakeTransport { _ in XCTFail("no request expected"); return .init(status: 500, body: "") }
        let session = session(store: store, transport: transport)
        _ = try await session.credentials()
        _ = try await session.credentials()
        let signedIn = await session.isSignedIn()
        XCTAssertTrue(signedIn)
        XCTAssertEqual(store.reads, 1, "a re-signed build prompts for the Keychain on every read; one per launch is the most a request may cost")
        try await session.signOut()
        let signedOut = await session.isSignedIn()
        XCTAssertFalse(signedOut)
        XCTAssertNil(try store.read("tokens"))
    }

    func testRefreshesWithinFiveMinutesOfExpiryAndRotatesTheRefreshToken() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(4 * 60), lastRefresh: clock.now)
        let newAccess = TestJWT.accessToken(expiresAt: clock.now.addingTimeInterval(3600))
        let transport = FakeTransport { _ in .init(status: 200, body: #"{"access_token":"\#(newAccess)","refresh_token":"rt_2"}"#) }
        let session = session(store: store, transport: transport)

        let credentials = try await session.credentials()
        XCTAssertEqual(credentials.accessToken, newAccess)
        let refresh = try XCTUnwrap(transport.requests(to: "/oauth/token").first)
        XCTAssertEqual(refresh.jsonBody?["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(refresh.jsonBody?["refresh_token"] as? String, "rt_1")
        XCTAssertEqual(refresh.jsonBody?["client_id"] as? String, ChatGPTEndpoints.clientID)
        let tokens = try JSONDecoder().decode(StoredTokens.self, from: XCTUnwrap(try store.read(ChatGPTSession.tokensAccount)))
        XCTAssertEqual(tokens.refreshToken, "rt_2")
        XCTAssertEqual(tokens.lastRefresh, clock.now)
    }

    func testRefreshesEightDaysAfterTheLastRefreshEvenWhenTheTokenIsValid() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(30 * 24 * 3600), lastRefresh: clock.now.addingTimeInterval(-8 * 24 * 3600 - 60))
        let transport = FakeTransport { _ in .init(status: 200, body: #"{"access_token":"a2"}"#) }
        let credentials = try await session(store: store, transport: transport).credentials()
        XCTAssertEqual(credentials.accessToken, "a2")
        let tokens = try JSONDecoder().decode(StoredTokens.self, from: XCTUnwrap(try store.read(ChatGPTSession.tokensAccount)))
        XCTAssertEqual(tokens.refreshToken, "rt_1", "a response without a new refresh token keeps the old one")
    }

    func testEachTerminalRefreshCodeSignsOut() async throws {
        let bodies = [
            #"{"error":{"code":"refresh_token_expired","message":"expired"}}"#,
            #"{"error":"refresh_token_reused"}"#,
            #"{"error":{"type":"invalid_request_error","code":"refresh_token_invalidated"}}"#,
        ]
        for body in bodies {
            let store = try storeWith(accessExpiry: clock.now, lastRefresh: clock.now)
            let transport = FakeTransport { _ in .init(status: 400, body: body) }
            do {
                _ = try await session(store: store, transport: transport).credentials()
                XCTFail("expected sign-in required for \(body)")
            } catch let error as AssistError {
                XCTAssertEqual(error, .signInRequired)
            }
            XCTAssertNil(try store.read(ChatGPTSession.tokensAccount), body)
        }
    }

    func testTransientRefreshFailureKeepsTheSignIn() async throws {
        let store = try storeWith(accessExpiry: clock.now, lastRefresh: clock.now)
        let transport = FakeTransport { _ in .init(status: 503, body: "") }
        do {
            _ = try await session(store: store, transport: transport).credentials()
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .server(provider: "OpenAI", status: 503, message: nil))
        }
        XCTAssertNotNil(try store.read(ChatGPTSession.tokensAccount))
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let store = try storeWith(accessExpiry: clock.now, lastRefresh: clock.now)
        let transport = FakeTransport { _ in .init(status: 200, body: #"{"access_token":"a2","refresh_token":"rt_2"}"#) }
        let session = session(store: store, transport: transport)
        async let first = session.credentials()
        async let second = session.credentials()
        let tokens = try await [first.accessToken, second.accessToken]
        XCTAssertEqual(tokens, ["a2", "a2"])
        XCTAssertEqual(transport.requests(to: "/oauth/token").count, 1)
    }

    func testSignedOutCredentialsRequireSignIn() async throws {
        let session = session(store: InMemorySecretStore(), transport: FakeTransport { _ in .init(status: 500, body: "") })
        do {
            _ = try await session.credentials()
            XCTFail("expected sign-in required")
        } catch let error as AssistError {
            XCTAssertEqual(error, .signInRequired)
        }
        let account = await session.account()
        XCTAssertNil(account)
    }

    func testSignOutDeletesTheKeychainItem() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        let session = session(store: store, transport: FakeTransport { _ in .init(status: 500, body: "") })
        let signedIn = await session.isSignedIn()
        XCTAssertTrue(signedIn)
        try await session.signOut()
        XCTAssertNil(try store.read(ChatGPTSession.tokensAccount))
        let signedOut = await session.isSignedIn()
        XCTAssertFalse(signedOut)
    }

    // MARK: Models

    func testModelListSendsTheBackendHeadersAndDropsHiddenModels() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        let body = try Fixture.text("chatgpt-models.json")
        let transport = FakeTransport { _ in .init(status: 200, body: body) }
        let models = try await session(store: store, transport: transport).models()

        XCTAssertEqual(models.map(\.slug), ["gpt-6-luna-light", "gpt-6-sol", "gpt-6-astra", "gpt-5.4-mini"])
        XCTAssertEqual(AssistModel.preferredDefault(in: models)?.displayName, "GPT-6 Luna (light)")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/models?client_version=\(ChatGPTEndpoints.clientVersion)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), ChatGPTEndpoints.originator)
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "acct_123")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Scribe/") == true)
    }

    func testDefaultModelFallsBackToTheFirstListed() {
        let models = [AssistModel(slug: "gpt-6-sol", displayName: "GPT-6 Sol"), AssistModel(slug: "gpt-6-luna", displayName: "GPT-6 Luna")]
        XCTAssertEqual(AssistModel.preferredDefault(in: models)?.slug, "gpt-6-sol")
        XCTAssertNil(AssistModel.preferredDefault(in: []))
    }

    func testModelList403IsNotAvailableForTheAccount() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        do {
            _ = try await session(store: store, transport: FakeTransport { _ in .init(status: 403, body: "") }).models()
            XCTFail("expected an error")
        } catch let error as AssistError {
            XCTAssertEqual(error, .notAvailableForAccount)
        }
    }

    // MARK: Assistant

    func testAssistantRefreshesOnceOn401ThenSucceeds() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        let sse = try Fixture.text("chatgpt-stream.sse")
        let responses = Counter()
        let transport = FakeTransport { request in
            if request.url!.path == "/oauth/token" { return .init(status: 200, body: #"{"access_token":"a2","refresh_token":"rt_2"}"#) }
            return responses.increment() == 1 ? .init(status: 401, body: "") : .init(status: 200, body: sse)
        }
        let assistant = ChatGPTAssistant(session: session(store: store, transport: transport), model: "gpt-6-luna", transport: transport)
        let response = try await assistant.respond(to: AssistRequest(instruction: "Reply", applicationName: "Mail", locale: "en"))
        XCTAssertTrue(response.text.hasPrefix("Hi Sam,"))
        XCTAssertEqual(response.usageLine, "1,204 in · 38 out")
        let sent = transport.requests(to: "/responses")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer a2")
        XCTAssertTrue((sent.last?.jsonBody?["instructions"] as? String)?.contains("in Mail.") == true)
    }

    func testAssistantReportsSignInAfterASecond401() async throws {
        let store = try storeWith(accessExpiry: clock.now.addingTimeInterval(3600), lastRefresh: clock.now)
        let transport = FakeTransport { request in
            request.url!.path == "/oauth/token"
                ? .init(status: 200, body: #"{"access_token":"a2"}"#)
                : .init(status: 401, body: "")
        }
        let assistant = ChatGPTAssistant(session: session(store: store, transport: transport), model: "m", transport: transport)
        do {
            _ = try await assistant.respond(to: AssistRequest(instruction: "x", locale: "en"))
            XCTFail("expected sign-in required")
        } catch let error as AssistError {
            XCTAssertEqual(error, .signInRequired)
        }
    }

    // MARK: Helpers

    private func storeWith(accessExpiry: Date, lastRefresh: Date) throws -> InMemorySecretStore {
        let store = InMemorySecretStore()
        let tokens = StoredTokens(
            idToken: TestJWT.idToken(),
            accessToken: TestJWT.accessToken(expiresAt: accessExpiry),
            refreshToken: "rt_1",
            accountID: "acct_123",
            lastRefresh: lastRefresh
        )
        try store.write(JSONEncoder().encode(tokens), for: ChatGPTSession.tokensAccount)
        return store
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { recorded } }
    func record(_ value: TimeInterval) { lock.withLock { recorded.append(value) } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// The count after incrementing.
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

/// Counts Keychain reads on behalf of a real store.
private final class CountingStore: SecretStore, @unchecked Sendable {
    private let wrapped: InMemorySecretStore
    private let lock = NSLock()
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    init(_ wrapped: InMemorySecretStore) { self.wrapped = wrapped }
    func read(_ account: String) throws -> Data? { lock.withLock { readCount += 1 }; return try wrapped.read(account) }
    func write(_ data: Data, for account: String) throws { try wrapped.write(data, for: account) }
    func delete(_ account: String) throws { try wrapped.delete(account) }
}
