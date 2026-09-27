import Foundation

/// The constants of the Codex sign-in route (proposal section 7.3), in one
/// place so a change on OpenAI's side is a one-line change here.
public enum ChatGPTEndpoints {
    public static let issuer = URL(string: "https://auth.openai.com")!
    /// Codex's public OAuth client id (`codex-rs/login/src/auth/manager.rs`).
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// The page where the person types the device code.
    public static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    public static let backendBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
    /// The `originator` header the backend gates on.
    ///
    /// Scribe sends the most honest value the backend accepts. The spike was
    /// to try `scribe`, then a Codex-prefixed value naming Scribe, then Codex's
    /// own value; only the last was exercised, and it passed on a real account
    /// in the QA pass of 2026-09-27 (docs/feasibility/assistant-qa-matrix.md),
    /// as the PM accepted. Replace it with a more honest value if one is shown
    /// to pass.
    public static let originator = "codex_cli_rs"
    /// The Codex release the models endpoint is asked to describe; it filters
    /// models by the minimum client version each one needs.
    public static let clientVersion = "0.157.1"
    /// Codex polls for the device code this long before giving up.
    public static let deviceCodeLifetime: TimeInterval = 15 * 60
    /// Codex refreshes when the access token expires within this window…
    public static let refreshWindow: TimeInterval = 5 * 60
    /// …or when the last refresh is older than this.
    public static let refreshInterval: TimeInterval = 8 * 24 * 60 * 60
    /// Refresh failures that mean the sign-in is gone and the person must sign in again.
    public static let terminalRefreshCodes: Set<String> = ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]

    /// Scribe's own User-Agent; only the originator identifies as Codex.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Scribe/\(version) (macOS)"
    }
}

/// Who is signed in, for Settings. Read from the `id_token`, never secret.
public struct ChatGPTAccount: Sendable, Equatable {
    public var accountID: String
    /// `chatgpt_plan_type`, e.g. "plus".
    public var planType: String?
    public var email: String?

    public init(accountID: String, planType: String?, email: String?) {
        self.accountID = accountID
        self.planType = planType
        self.email = email
    }

    /// "Plus", "Pro", "Business"…; nil when the token names no plan.
    public var planName: String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "team": return "Business"
        case "edu": return "Edu"
        default: return planType.prefix(1).uppercased() + planType.dropFirst()
        }
    }
}

/// A device sign-in in progress: what the card shows while the person types the code.
public struct DeviceSignIn: Sendable, Equatable {
    public var userCode: String
    public var verificationURL: URL
    public var expiresAt: Date
    let deviceAuthID: String
    let interval: TimeInterval
}

public enum ChatGPTSignInError: Error, Equatable, LocalizedError {
    case codeRequestFailed(String)
    case timedOut
    case denied(String)
    case exchangeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .codeRequestFailed(let reason): "OpenAI did not issue a sign-in code. \(reason)"
        case .timedOut: "The sign-in code expired before it was entered. Start again to get a new one."
        case .denied(let reason): "Sign-in was not completed. \(reason)"
        case .exchangeFailed(let reason): "OpenAI did not finish the sign-in. \(reason)"
        }
    }
}

/// The ChatGPT sign-in Scribe owns: the device-code flow `codex login
/// --device-auth` uses, tokens in the Keychain, and Codex's refresh rule.
///
/// It never reads or writes `~/.codex`; that file belongs to Codex, which
/// rotates it independently.
public actor ChatGPTSession {
    static let tokensAccount = "tokens"

    private let store: SecretStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var refreshTask: Task<StoredTokens, Error>?
    /// The tokens once read this launch. The Keychain is asked once, not per
    /// request: every read of an item the app did not create under its current
    /// signature (a re-signed development build) shows the person a Keychain
    /// prompt, and a request should never do that twice.
    private var cachedTokens: StoredTokens?

    public init(
        store: SecretStore = KeychainStore(service: KeychainStore.chatGPTService),
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.store = store
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    /// Whether tokens are stored, without reading them.
    public func isSignedIn() -> Bool {
        cachedTokens != nil || ((try? store.contains(Self.tokensAccount)) ?? false)
    }

    /// The signed-in account, or nil when there is none.
    public func account() -> ChatGPTAccount? {
        (try? loadTokens())?.account
    }

    // MARK: Device sign-in

    /// Asks for a user code. Show it, then call `completeDeviceSignIn`.
    public func beginDeviceSignIn() async throws -> DeviceSignIn {
        let url = ChatGPTEndpoints.issuer.appending(path: "api/accounts/deviceauth/usercode")
        let (data, response) = try await send(json(url, ["client_id": ChatGPTEndpoints.clientID]), failure: ChatGPTSignInError.codeRequestFailed)
        guard response.statusCode == 200, let object = Self.object(data),
              let deviceAuthID = object["device_auth_id"] as? String,
              let userCode = (object["user_code"] ?? object["usercode"]) as? String else {
            throw ChatGPTSignInError.codeRequestFailed(Self.reason(status: response.statusCode, data: data))
        }
        let interval = Self.number(object["interval"]) ?? 5
        var lifetime = ChatGPTEndpoints.deviceCodeLifetime
        if let expiresIn = Self.number(object["expires_in"]) { lifetime = min(lifetime, expiresIn) }
        return DeviceSignIn(
            userCode: userCode,
            verificationURL: ChatGPTEndpoints.verificationURL,
            expiresAt: now().addingTimeInterval(lifetime),
            deviceAuthID: deviceAuthID,
            interval: max(interval, 1)
        )
    }

    /// Polls at the server's interval until the code is entered or expires,
    /// then exchanges it and stores the tokens. Cancel the task to stop.
    public func completeDeviceSignIn(_ pending: DeviceSignIn) async throws -> ChatGPTAccount {
        let url = ChatGPTEndpoints.issuer.appending(path: "api/accounts/deviceauth/token")
        var grant: [String: Any]?
        while now() < pending.expiresAt {
            try Task.checkCancellation()
            let (data, response) = try await send(
                json(url, ["device_auth_id": pending.deviceAuthID, "user_code": pending.userCode]),
                failure: ChatGPTSignInError.denied
            )
            switch response.statusCode {
            case 200:
                grant = Self.object(data)
            case 403, 404:
                // Not entered yet.
                try await sleep(pending.interval)
                continue
            default:
                throw ChatGPTSignInError.denied(Self.reason(status: response.statusCode, data: data))
            }
            break
        }
        guard let grant else { throw ChatGPTSignInError.timedOut }
        guard let code = grant["authorization_code"] as? String, let verifier = grant["code_verifier"] as? String else {
            throw ChatGPTSignInError.exchangeFailed("The response had no authorization code.")
        }

        var request = URLRequest(url: ChatGPTEndpoints.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(ChatGPTEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = FormEncoding.encode([
            ("grant_type", "authorization_code"),
            ("client_id", ChatGPTEndpoints.clientID),
            ("code", code),
            ("redirect_uri", ChatGPTEndpoints.issuer.appending(path: "deviceauth/callback").absoluteString),
            ("code_verifier", verifier),
        ])
        let (data, response) = try await send(request, failure: ChatGPTSignInError.exchangeFailed)
        guard response.statusCode == 200, let object = Self.object(data),
              let idToken = object["id_token"] as? String,
              let accessToken = object["access_token"] as? String,
              let refreshToken = object["refresh_token"] as? String else {
            throw ChatGPTSignInError.exchangeFailed(Self.reason(status: response.statusCode, data: data))
        }
        guard let claims = JWT.authClaims(idToken), let accountID = claims.accountID else {
            throw ChatGPTSignInError.exchangeFailed("The sign-in named no ChatGPT account.")
        }
        let tokens = StoredTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken, accountID: accountID, lastRefresh: now())
        try saveTokens(tokens)
        return tokens.account
    }

    // MARK: Using the sign-in

    /// A current access token and the account id, refreshed first when Codex's
    /// rule says so, or when `forceRefresh` (after a 401).
    public func credentials(forceRefresh: Bool = false) async throws -> (accessToken: String, accountID: String) {
        guard var tokens = try loadTokens() else { throw AssistError.signInRequired }
        if forceRefresh || needsRefresh(tokens) {
            tokens = try await refreshed(tokens)
        }
        return (tokens.accessToken, tokens.accountID)
    }

    /// The headers every backend request carries.
    public nonisolated static func backendHeaders(accessToken: String, accountID: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "chatgpt-account-id": accountID,
            "originator": ChatGPTEndpoints.originator,
            "User-Agent": ChatGPTEndpoints.userAgent,
        ]
    }

    /// The models this account may use, in the backend's order.
    public func models() async throws -> [AssistModel] {
        var credentials = try await credentials()
        for attempt in 0..<2 {
            var components = URLComponents(url: ChatGPTEndpoints.backendBaseURL.appending(path: "models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "client_version", value: ChatGPTEndpoints.clientVersion)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for (name, value) in Self.backendHeaders(accessToken: credentials.accessToken, accountID: credentials.accountID) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (data, response) = try await send(request, failure: AssistError.network)
            switch response.statusCode {
            case 200:
                return Self.parseModels(data)
            case 401 where attempt == 0:
                credentials = try await self.credentials(forceRefresh: true)
            case 401:
                throw AssistError.signInRequired
            case 403:
                throw AssistError.notAvailableForAccount
            default:
                throw AssistError.server(status: response.statusCode, message: ResponsesErrorBody(json: String(decoding: data, as: UTF8.self))?.message)
            }
        }
        throw AssistError.signInRequired
    }

    /// Deletes the Keychain items. OpenAI keeps the grant until it expires;
    /// the person can revoke it from their ChatGPT account's security settings.
    public func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        cachedTokens = nil
        try store.delete(Self.tokensAccount)
    }

    // MARK: Refresh

    func needsRefresh(_ tokens: StoredTokens) -> Bool {
        let current = now()
        if current.timeIntervalSince(tokens.lastRefresh) > ChatGPTEndpoints.refreshInterval { return true }
        guard let expiry = JWT.expiry(tokens.accessToken) else { return false }
        return expiry.timeIntervalSince(current) < ChatGPTEndpoints.refreshWindow
    }

    /// One refresh at a time: refresh tokens rotate, so a second concurrent
    /// refresh with the same token would be reported as reuse and end the sign-in.
    private func refreshed(_ tokens: StoredTokens) async throws -> StoredTokens {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ tokens: StoredTokens) async throws -> StoredTokens {
        var request = URLRequest(url: ChatGPTEndpoints.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ChatGPTEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": ChatGPTEndpoints.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "scope": "openid profile email",
        ])
        let (data, response) = try await send(request, failure: AssistError.network)
        guard response.statusCode == 200 else {
            let body = ResponsesErrorBody(json: String(decoding: data, as: UTF8.self))
            let code = body?.code ?? body?.type
            if response.statusCode == 401 || code.map(ChatGPTEndpoints.terminalRefreshCodes.contains) == true {
                cachedTokens = nil
                try? store.delete(Self.tokensAccount)
                throw AssistError.signInRequired
            }
            throw AssistError.server(status: response.statusCode, message: body?.message)
        }
        let object = Self.object(data) ?? [:]
        var updated = tokens
        if let idToken = object["id_token"] as? String {
            updated.idToken = idToken
            if let accountID = JWT.authClaims(idToken)?.accountID { updated.accountID = accountID }
        }
        if let accessToken = object["access_token"] as? String { updated.accessToken = accessToken }
        if let refreshToken = object["refresh_token"] as? String { updated.refreshToken = refreshToken }
        updated.lastRefresh = now()
        try saveTokens(updated)
        return updated
    }

    // MARK: Storage

    private func loadTokens() throws -> StoredTokens? {
        if let cachedTokens { return cachedTokens }
        guard let data = try store.read(Self.tokensAccount) else { return nil }
        cachedTokens = try? JSONDecoder().decode(StoredTokens.self, from: data)
        return cachedTokens
    }

    private func saveTokens(_ tokens: StoredTokens) throws {
        try store.write(JSONEncoder().encode(tokens), for: Self.tokensAccount)
        cachedTokens = tokens
    }

    // MARK: HTTP

    private func json(_ url: URL, _ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ChatGPTEndpoints.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send<E: Error>(_ request: URLRequest, failure: (String) -> E) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw failure(error.localizedDescription)
        }
    }

    static func parseModels(_ data: Data) -> [AssistModel] {
        let entries = (object(data)?["models"] as? [[String: Any]]) ?? []
        return entries
            .filter { ($0["visibility"] as? String).map { !["hide", "hidden", "none"].contains($0) } ?? true }
            .enumerated()
            .sorted { lhs, rhs in
                let l = number(lhs.element["priority"]) ?? .infinity
                let r = number(rhs.element["priority"]) ?? .infinity
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .compactMap { entry in
                guard let slug = entry.element["slug"] as? String else { return nil }
                let name = entry.element["display_name"] as? String ?? slug
                return AssistModel(slug: slug, displayName: name)
            }
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func reason(status: Int, data: Data) -> String {
        if let message = ResponsesErrorBody(json: String(decoding: data, as: UTF8.self))?.message { return message }
        return "HTTP \(status)."
    }
}

/// What the Keychain item holds: the three tokens, the account id, and when
/// they were last refreshed.
struct StoredTokens: Codable, Equatable, Sendable {
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accountID: String
    var lastRefresh: Date

    var account: ChatGPTAccount {
        let claims = JWT.authClaims(idToken)
        return ChatGPTAccount(accountID: accountID, planType: claims?.planType, email: claims?.email)
    }
}

/// Reads JWT payloads without verifying them: the tokens came straight from
/// OpenAI over TLS, and the claims are only used for display and routing.
enum JWT {
    struct AuthClaims {
        var accountID: String?
        var planType: String?
        var email: String?
    }

    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The `https://api.openai.com/auth` claim of an `id_token`, plus its email.
    static func authClaims(_ idToken: String) -> AuthClaims? {
        guard let payload = payload(idToken) else { return nil }
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return AuthClaims(
            accountID: auth?["chatgpt_account_id"] as? String,
            planType: auth?["chatgpt_plan_type"] as? String,
            email: payload["email"] as? String ?? profile?["email"] as? String
        )
    }

    static func expiry(_ token: String) -> Date? {
        guard let exp = payload(token)?["exp"] else { return nil }
        if let exp = exp as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = exp as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        return nil
    }
}
