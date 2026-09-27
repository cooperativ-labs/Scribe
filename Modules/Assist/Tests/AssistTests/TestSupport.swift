@testable import Assist
import Foundation

/// Answers requests from a closure and remembers them, so a test can check
/// what was sent as well as what came back.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: String
    }

    private let lock = NSLock()
    private var handler: (URLRequest) throws -> Reply
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) throws -> Reply) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = try record(request)
        return (Data(reply.body.utf8), response(request, reply))
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let reply = try record(request)
        let lines = reply.body.components(separatedBy: "\n")
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (response(request, reply), stream)
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func requests(to path: String) -> [URLRequest] {
        lock.withLock { requests.filter { $0.url?.path.hasSuffix(path) == true } }
    }

    private func record(_ request: URLRequest) throws -> Reply {
        let handler = lock.withLock { () -> (URLRequest) throws -> Reply in
            requests.append(request)
            return self.handler
        }
        return try handler(request)
    }

    private func response(_ request: URLRequest, _ reply: Reply) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    }
}

enum Fixture {
    static func text(_ name: String) throws -> String {
        let url = try XCTUnwrapURL(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func XCTUnwrapURL(_ url: URL?) throws -> URL {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}

enum TestJWT {
    /// An unsigned JWT with `claims` as its payload; the session never verifies signatures.
    static func make(_ claims: [String: Any]) -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(part(["alg": "none", "typ": "JWT"])).\(part(claims)).sig"
    }

    static func idToken(accountID: String = "acct_123", plan: String = "plus", email: String = "person@example.com") -> String {
        make([
            "email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID, "chatgpt_plan_type": plan],
        ])
    }

    static func accessToken(expiresAt: Date) -> String {
        make(["exp": expiresAt.timeIntervalSince1970])
    }
}

extension URLRequest {
    var jsonBody: [String: Any]? {
        httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    var formBody: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1].removingPercentEncoding }
        }
        return fields
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
