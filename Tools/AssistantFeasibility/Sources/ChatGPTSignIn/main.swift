import AppKit
import Foundation

// Part A of the assistant feasibility spike: the OpenAI device-code flow that
// `codex login --device-auth` performs, from a client that is not Codex, then
// a few streamed Responses requests against chatgpt.com/backend-api/codex.
//
// Nothing is persisted. Tokens live in this process only. ~/.codex is never read.
// The log prints statuses, header names, latencies, counts and error bodies; it
// never prints tokens or the generated text. The User-Agent is always Scribe's
// own; only the originator header cycles through the candidate values.

let issuer = "https://auth.openai.com"
let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"          // Codex's public client id (codex-rs/login/src/auth/manager.rs)
let codexBase = "https://chatgpt.com/backend-api/codex"
let codexVersion = "0.157.1"                            // the Codex CLI installed on this Mac; only used in the models query
let userAgent = "Scribe-feasibility/0.1 (macOS)"
var originatorCandidates = ["scribe", "codex_scribe", "Codex-Scribe", "codex_cli_rs"]

let started = Date()
@MainActor func log(_ message: String) {
    let t = String(format: "%7.2fs", Date().timeIntervalSince(started))
    print("[\(t)] \(message)")
    fflush(stdout)
}

struct HTTPResult {
    let status: Int
    let headers: [String: String]
    let body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    func json() -> [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

@MainActor func request(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil, contentType: String? = nil) async throws -> HTTPResult {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.timeoutInterval = 60
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    req.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: req)
    let http = response as! HTTPURLResponse
    var hs: [String: String] = [:]
    for (k, v) in http.allHeaderFields { hs[String(describing: k).lowercased()] = String(describing: v) }
    return HTTPResult(status: http.statusCode, headers: hs, body: data)
}

@MainActor func postJSON(_ url: String, _ object: [String: Any], headers: [String: String] = [:]) async throws -> HTTPResult {
    try await request("POST", url, headers: headers, body: try JSONSerialization.data(withJSONObject: object), contentType: "application/json")
}

func formEncode(_ pairs: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").data(using: .utf8)!
}

func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    guard let d = Data(base64Encoded: s) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func interestingHeaders(_ h: [String: String]) -> String {
    h.filter { k, _ in k.hasPrefix("x-") || ["content-type", "retry-after", "www-authenticate", "openai-model", "openai-version", "cf-ray"].contains(k) }
        .map { ["x-oai-is-update", "x-codex-turn-state", "set-cookie"].contains($0.key) ? "\($0.key)=<\($0.value.count) chars>" : "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
}

// MARK: - Device-code flow (codex-rs/login/src/device_code_auth.rs)

struct Tokens { var idToken: String; var accessToken: String; var refreshToken: String }

@MainActor func deviceCodeSignIn() async throws -> Tokens {
    let api = "\(issuer)/api/accounts"
    log("POST \(api)/deviceauth/usercode from a non-Codex client (User-Agent \(userAgent))")
    let uc = try await postJSON("\(api)/deviceauth/usercode", ["client_id": clientID])
    log("usercode → HTTP \(uc.status) \(interestingHeaders(uc.headers))")
    guard uc.status == 200, let j = uc.json(),
          let deviceAuthID = j["device_auth_id"] as? String,
          let userCode = (j["user_code"] ?? j["usercode"]) as? String else {
        log("usercode body: \(uc.text)")
        throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "usercode request failed"])
    }
    let interval = (j["interval"] as? Double) ?? Double((j["interval"] as? String) ?? "") ?? 5
    log("usercode body keys: \(j.keys.sorted()); interval=\(interval)s; user_code length=\(userCode.count); device_auth_id length=\(deviceAuthID.count)")
    let verification = "\(issuer)/codex/device"
    print("""

    ==================================================================
      Sign in with your own ChatGPT account.
      1. Open  \(verification)
      2. Enter the one-time code:   \(userCode)
      (The code was also copied to the clipboard and the page opened.)
      Waiting up to 15 minutes.
    ==================================================================

    """)
    fflush(stdout)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(userCode, forType: .string)
    NSWorkspace.shared.open(URL(string: verification)!)

    let deadline = Date().addingTimeInterval(15 * 60)
    var polls = 0
    var codeResp: [String: Any]?
    while Date() < deadline {
        let r = try await postJSON("\(api)/deviceauth/token", ["device_auth_id": deviceAuthID, "user_code": userCode])
        polls += 1
        if r.status == 200 { codeResp = r.json(); log("token poll → 200 after \(polls) polls; keys: \(codeResp?.keys.sorted() ?? [])"); break }
        if r.status == 403 || r.status == 404 {
            if polls == 1 || polls % 12 == 0 { log("token poll → \(r.status) (pending) ×\(polls)") }
            try await Task.sleep(for: .seconds(interval))
            continue
        }
        log("token poll → HTTP \(r.status) body: \(r.text)")
        throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "device auth failed"])
    }
    guard let codeResp,
          let authorizationCode = codeResp["authorization_code"] as? String,
          let verifier = codeResp["code_verifier"] as? String else {
        throw NSError(domain: "spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "device auth timed out"])
    }
    log("exchange: POST \(issuer)/oauth/token (form) grant_type=authorization_code redirect_uri=\(issuer)/deviceauth/callback")
    let ex = try await request("POST", "\(issuer)/oauth/token",
                               body: formEncode([("grant_type", "authorization_code"), ("client_id", clientID), ("code", authorizationCode),
                                                 ("redirect_uri", "\(issuer)/deviceauth/callback"), ("code_verifier", verifier)]),
                               contentType: "application/x-www-form-urlencoded")
    log("exchange → HTTP \(ex.status) \(interestingHeaders(ex.headers))")
    guard ex.status == 200, let tj = ex.json(),
          let id = tj["id_token"] as? String, let access = tj["access_token"] as? String, let refresh = tj["refresh_token"] as? String else {
        log("exchange body: \(ex.text)")
        throw NSError(domain: "spike", code: 4, userInfo: [NSLocalizedDescriptionKey: "exchange failed"])
    }
    let otherKeys = tj.keys.filter { !["id_token", "access_token", "refresh_token"].contains($0) }.sorted()
    log("token shape: id_token(\(id.count) chars, JWT=\(id.split(separator: ".").count == 3)) access_token(\(access.count) chars, JWT=\(access.split(separator: ".").count == 3)) refresh_token(\(refresh.count) chars, JWT=\(refresh.split(separator: ".").count == 3)); other keys: \(otherKeys.map { $0 == "oai_is" ? "oai_is=<\(String(describing: tj[$0] ?? "").count) chars>" : "\($0)=\(tj[$0] ?? "")" })")
    describeClaims("id_token", id)
    describeClaims("access_token", access)
    return Tokens(idToken: id, accessToken: access, refreshToken: refresh)
}

@MainActor func describeClaims(_ name: String, _ token: String) {
    guard let p = jwtPayload(token) else { log("\(name): not a decodable JWT"); return }
    var summary: [String] = []
    for k in p.keys.sorted() {
        switch k {
        case "exp", "iat", "nbf":
            if let v = p[k] as? Double { summary.append("\(k)=\(Date(timeIntervalSince1970: v)) (\(Int((v - Date().timeIntervalSince1970) / 60)) min from now)") }
        case "https://api.openai.com/auth":
            if let auth = p[k] as? [String: Any] {
                let redacted = auth.map { ak, av -> String in
                    if ak == "chatgpt_plan_type" || av is Bool { return "\(ak)=\(av)" }
                    return "\(ak)=<\(String(describing: av).count) chars>"
                }
                summary.append("\(k)={\(redacted.sorted().joined(separator: ", "))}")
            }
        case "https://api.openai.com/profile":
            if let prof = p[k] as? [String: Any] { summary.append("\(k)=keys\(prof.keys.sorted())") }
        default:
            summary.append("\(k)=<\(String(describing: p[k]!).count) chars>")
        }
    }
    log("\(name) claims: \(summary.joined(separator: "; "))")
}

@MainActor func accountID(from idToken: String) -> String? {
    (jwtPayload(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
}

@MainActor func planType(from idToken: String) -> String? {
    (jwtPayload(idToken)?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
}

// MARK: - Model list

@MainActor func listModels(tokens: Tokens, originator: String) async throws -> (HTTPResult, [[String: Any]]) {
    let url = "\(codexBase)/models?client_version=\(codexVersion)"
    var headers = ["Authorization": "Bearer \(tokens.accessToken)", "originator": originator, "Accept": "application/json"]
    if let acc = accountID(from: tokens.idToken) { headers["chatgpt-account-id"] = acc }
    let r = try await request("GET", url, headers: headers)
    let models = (r.json()?["models"] as? [[String: Any]]) ?? []
    return (r, models)
}

// MARK: - Streamed Responses request

struct StreamOutcome {
    var status = 0
    var headers: [String: String] = [:]
    var firstDelta: TimeInterval?
    var completed: TimeInterval?
    var outputChars = 0
    var eventCounts: [String: Int] = [:]
    var errorBody = ""
    var completedResponseKeys: [String] = []
    var usage: String = ""
}

@MainActor func streamResponses(url: String, headers: [String: String], body: [String: Any]) async -> StreamOutcome {
    var outcome = StreamOutcome()
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.httpBody = try! JSONSerialization.data(withJSONObject: body)
    let t0 = Date()
    do {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let http = response as! HTTPURLResponse
        outcome.status = http.statusCode
        for (k, v) in http.allHeaderFields { outcome.headers[String(describing: k).lowercased()] = String(describing: v) }
        if http.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            outcome.errorBody = String(decoding: data, as: UTF8.self)
            return outcome
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let d = payload.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let type = (j["type"] as? String) ?? "?"
            outcome.eventCounts[type, default: 0] += 1
            switch type {
            case "response.output_text.delta":
                if outcome.firstDelta == nil { outcome.firstDelta = Date().timeIntervalSince(t0) }
                outcome.outputChars += ((j["delta"] as? String) ?? "").count
            case "response.completed", "response.incomplete", "response.failed":
                outcome.completed = Date().timeIntervalSince(t0)
                if let r = j["response"] as? [String: Any] {
                    outcome.completedResponseKeys = r.keys.sorted()
                    if let u = r["usage"] { outcome.usage = String(describing: u).replacingOccurrences(of: "\n", with: " ") }
                    if let e = r["error"], !(e is NSNull) { outcome.errorBody = String(describing: e) }
                }
            case "error":
                outcome.errorBody = payload
            default: break
            }
        }
        if outcome.completed == nil { outcome.completed = Date().timeIntervalSince(t0) }
    } catch {
        outcome.errorBody = "transport error: \(error)"
    }
    return outcome
}

let systemPrompt = """
You are a writing assistant inside a macOS dictation app. The user spoke an instruction. \
Apply it to the provided text and return only the resulting text, with no preamble.
"""

func threadPrompt() -> String {
    var thread = "<screen_text app=\"Mail\">\n"
    for i in 1...6 {
        thread += """
        From: Person \(i) <person\(i)@example.com>
        Subject: Re: Q4 vendor renewal and the migration timeline
        Thanks for the update. On our side the renewal terms look acceptable if the support tier stays the same, \
        but we still need clarity on the migration window. Engineering estimates three weeks for the data move and \
        one more for validation, which pushes the cut-over into early December. Can you confirm whether the vendor \
        will hold pricing through the end of the year and whether the sandbox environment remains available during \
        the validation phase? If not, we may need to renew for a shorter term and revisit in March.\n\n
        """
    }
    thread += "</screen_text>\n<instruction>\nReply to this thread saying we will confirm pricing by Friday and ask them to keep the sandbox open until validation ends.\n</instruction>"
    return thread
}

func responsesBody(model: String, prompt: String, minimal: Bool) -> [String: Any] {
    var body: [String: Any] = [
        "model": model,
        "instructions": systemPrompt,
        "input": [["type": "message", "role": "user", "content": [["type": "input_text", "text": prompt]]]],
        "store": false,
        "stream": true,
    ]
    if !minimal {
        // What Codex always sends alongside (codex-rs/core/src/client.rs): no tools, auto choice, low reasoning, no includes.
        body["tools"] = [] as [Any]
        body["tool_choice"] = "auto"
        body["parallel_tool_calls"] = false
        body["reasoning"] = ["effort": "low"]
        body["include"] = [] as [Any]
    }
    return body
}

@MainActor func describe(_ o: StreamOutcome, label: String) {
    let ft = o.firstDelta.map { String(format: "%.2fs", $0) } ?? "–"
    let done = o.completed.map { String(format: "%.2fs", $0) } ?? "–"
    log("\(label): HTTP \(o.status) first-token=\(ft) completed=\(done) output=\(o.outputChars) chars events=\(o.eventCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ",")) headers: \(interestingHeaders(o.headers))")
    if !o.usage.isEmpty { log("  usage: \(o.usage)") }
    if !o.completedResponseKeys.isEmpty { log("  response keys: \(o.completedResponseKeys)") }
    if !o.errorBody.isEmpty { log("  error body: \(o.errorBody.prefix(2000))") }
}

// MARK: - Refresh

@MainActor func refresh(_ tokens: Tokens) async throws -> Tokens? {
    log("refresh: POST \(issuer)/oauth/token (form) grant_type=refresh_token")
    let r = try await request("POST", "\(issuer)/oauth/token",
                              body: formEncode([("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", tokens.refreshToken)]),
                              contentType: "application/x-www-form-urlencoded")
    log("refresh → HTTP \(r.status) \(interestingHeaders(r.headers))")
    guard r.status == 200, let j = r.json() else { log("refresh body: \(r.text)"); return nil }
    let newRefresh = j["refresh_token"] as? String
    let newAccess = j["access_token"] as? String
    log("refresh body keys: \(j.keys.sorted()); refresh_token rotated=\(newRefresh != nil && newRefresh != tokens.refreshToken); access_token changed=\(newAccess != nil && newAccess != tokens.accessToken)")
    if let a = newAccess { describeClaims("refreshed access_token", a) }
    return Tokens(idToken: (j["id_token"] as? String) ?? tokens.idToken, accessToken: newAccess ?? tokens.accessToken, refreshToken: newRefresh ?? tokens.refreshToken)
}

// MARK: - Main

@MainActor func runSignIn() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        var skipAPIKey = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--no-api-key": skipAPIKey = true
            case "--originators": originatorCandidates = args.removeFirst().split(separator: ",").map(String.init)
            default: log("unknown argument \(a)"); exit(64)
            }
        }
        log("chatgpt-signin spike start; pid \(getpid()); originator candidates \(originatorCandidates)")
        var tokens: Tokens
        do { tokens = try await deviceCodeSignIn() } catch { log("SIGN-IN FAILED: \(error.localizedDescription)"); exit(1) }
        log("signed in; plan=\(planType(from: tokens.idToken) ?? "?") account id present=\(accountID(from: tokens.idToken) != nil)")

        // 1. Model list, honest originator first.
        var models: [[String: Any]] = []
        for o in originatorCandidates {
            do {
                let (r, m) = try await listModels(tokens: tokens, originator: o)
                log("GET /models originator=\(o) → HTTP \(r.status) \(interestingHeaders(r.headers)) models=\(m.count)")
                if r.status == 200 { models = m; break }
                log("  body: \(r.text.prefix(1500))")
            } catch { log("GET /models originator=\(o) transport error: \(error)") }
        }
        if !models.isEmpty {
            log("models top-level keys of first entry: \((models.first?.keys.sorted()) ?? [])")
            for m in models {
                let slug = (m["slug"] as? String) ?? "?"
                let name = (m["display_name"] as? String) ?? (m["name"] as? String) ?? ""
                let extra = ["priority", "supported_in_api", "visibility", "show_in_picker", "is_default", "default_reasoning_level", "supported_reasoning_levels", "minimal_client_version"]
                    .compactMap { k in m[k].map { "\(k)=\(String(describing: $0).replacingOccurrences(of: "\n", with: ""))" } }
                log("  model slug=\(slug) display=\"\(name)\" \(extra.joined(separator: " "))")
            }
        }
        func lunaLight(_ m: [String: Any]) -> Bool {
            let s = ((m["slug"] as? String) ?? "") + " " + ((m["display_name"] as? String) ?? "")
            return s.lowercased().contains("luna") && s.lowercased().contains("light")
        }
        func pickModel() -> String {
            if let m = models.first(where: lunaLight) { return m["slug"] as! String }
            if let m = models.first(where: { (($0["slug"] as? String) ?? "").lowercased().contains("luna") }) { return m["slug"] as! String }
            return (models.first?["slug"] as? String) ?? "gpt-5.4-mini"
        }
        let model = pickModel()
        log("model for requests: \(model) (Luna light present: \(models.contains(where: lunaLight)))")

        // 2. Originator gate: short prompt, each candidate in order.
        var winner: String?
        let gatePrompt = "<selected_text>\nplease send me the report by monday\n</selected_text>\n<instruction>\nFix the capitalisation.\n</instruction>"
        for o in originatorCandidates {
            var h = ["Authorization": "Bearer \(tokens.accessToken)", "originator": o]
            if let acc = accountID(from: tokens.idToken) { h["chatgpt-account-id"] = acc }
            let out = await streamResponses(url: "\(codexBase)/responses", headers: h, body: responsesBody(model: model, prompt: gatePrompt, minimal: false))
            describe(out, label: "gate originator=\(o)")
            if out.status == 200 && out.errorBody.isEmpty { winner = o; break }
        }
        guard let winner else { log("NO ORIGINATOR PASSED; stopping before latency runs"); exit(2) }
        log("most honest passing originator: \(winner)")

        // 3. Thread-sized prompt: latency, twice (cold and warm), full body then minimal body.
        var h = ["Authorization": "Bearer \(tokens.accessToken)", "originator": winner]
        if let acc = accountID(from: tokens.idToken) { h["chatgpt-account-id"] = acc }
        let prompt = threadPrompt()
        log("thread prompt: \(prompt.count) chars")
        for i in 1...2 {
            let out = await streamResponses(url: "\(codexBase)/responses", headers: h, body: responsesBody(model: model, prompt: prompt, minimal: false))
            describe(out, label: "thread run \(i) (codex-style body)")
        }
        let minimalOut = await streamResponses(url: "\(codexBase)/responses", headers: h, body: responsesBody(model: model, prompt: prompt, minimal: true))
        describe(minimalOut, label: "thread run 3 (minimal body: model, instructions, input, store, stream)")
        var hNoAccount = h; hNoAccount["chatgpt-account-id"] = nil
        let noAcc = await streamResponses(url: "\(codexBase)/responses", headers: hNoAccount, body: responsesBody(model: model, prompt: gatePrompt, minimal: false))
        describe(noAcc, label: "gate without chatgpt-account-id header")
        let badModel = await streamResponses(url: "\(codexBase)/responses", headers: h, body: responsesBody(model: "gpt-5-codex", prompt: gatePrompt, minimal: false))
        describe(badModel, label: "retired model slug gpt-5-codex")

        // 4. Refresh once, then discard.
        do { if let t = try await refresh(tokens) { tokens = t } } catch { log("refresh transport error: \(error)") }

        // 5. API-key path against api.openai.com, only if the environment provides a key.
        if !skipAPIKey, let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            let list = try? await request("GET", "https://api.openai.com/v1/models", headers: ["Authorization": "Bearer \(key)"])
            var apiModel = "gpt-5-mini"
            if let list, list.status == 200, let data = list.json()?["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("gpt-") && !$0.contains("realtime") && !$0.contains("audio") && !$0.contains("image") }.sorted()
                log("api.openai.com /v1/models → \(ids.count) gpt-* ids: \(ids.joined(separator: ", "))")
                if let luna = ids.first(where: { $0.contains("luna") }) { apiModel = luna }
                else if let mini = ids.first(where: { $0.hasPrefix("gpt-5") && $0.contains("mini") }) { apiModel = mini }
            } else { log("api.openai.com /v1/models → HTTP \(list?.status ?? -1) \(list?.text.prefix(500) ?? "")") }
            let out = await streamResponses(url: "https://api.openai.com/v1/responses", headers: ["Authorization": "Bearer \(key)"],
                                            body: responsesBody(model: apiModel, prompt: prompt, minimal: true))
            describe(out, label: "api.openai.com /v1/responses model=\(apiModel) minimal body")
        } else {
            log("api.openai.com path skipped: OPENAI_API_KEY not in this process environment (run with the key exported to exercise it)")
        }
        log("done; tokens discarded with the process (nothing written to disk or Keychain)")
    }

await runSignIn()
