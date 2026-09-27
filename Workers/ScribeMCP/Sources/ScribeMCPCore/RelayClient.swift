import Foundation
import MCP
import Transcription

public struct RelayFailure: LocalizedError, Sendable {
    public let message: String
    public let status: Int?
    public var errorDescription: String? { message }
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
}

/// The same relay.json used by earlier Node releases. A new link is written
/// through a private temporary file before replacing the previous file.
public struct RelayCredentialsStore: Sendable {
    public struct Credentials: Codable, Sendable {
        public let relay: String
        public let owner_id: String
        public let agent_secret: String
        public let linked_at: String?
    }

    public let file: URL
    public init(file: URL) { self.file = file }

    public func read() throws -> Credentials? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: file))
            guard !value.relay.isEmpty, !value.owner_id.isEmpty, !value.agent_secret.isEmpty else { throw RelayFailure("Relay link file is invalid. Unlink and link again.") }
            return value
        } catch { throw RelayFailure("Relay link file is invalid. Unlink and link again.") }
    }

    public func write(_ value: Credentials) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appending(path: ".relay-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw RelayFailure("Could not save the relay link.") }
        defer { close(descriptor) }
        do {
            var data = try JSONEncoder().encode(value)
            data.append(0x0A)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw RelayFailure("Could not save the relay link.") }
                    offset += count
                }
            }
            guard rename(temporary.path, file.path) == 0 else { throw RelayFailure("Could not save the relay link.") }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

/// Outbound relay protocol. The Node service and its wire format stay unchanged.
public actor RelayClient {
    public let credentials: RelayCredentialsStore
    private let library: TranscriptLibrary
    private let session: URLSession

    public init(credentials: RelayCredentialsStore, transcriptDirectory: URL, session: URLSession? = nil) {
        self.credentials = credentials
        self.library = TranscriptLibrary(store: TranscriptStore(storeDirectoryURL: transcriptDirectory))
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: RelayNoRedirect(), delegateQueue: nil)
    }

    public func link(origin: String) async throws {
        guard let url = URL(string: origin),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")) else {
            throw RelayFailure("The relay address must be an HTTPS origin such as https://relay.example.com.")
        }
        if let existing = try credentials.read() {
            guard existing.relay == origin else { throw RelayFailure("Already linked to \(existing.relay). Unlink first to change relays.") }
            return
        }
        let response = try await request(origin: origin, route: "/agent/register")
        guard let owner = response["owner_id"] as? String, !owner.isEmpty,
              let secret = response["agent_secret"] as? String, !secret.isEmpty else {
            throw RelayFailure("The relay returned an invalid link.")
        }
        try credentials.write(.init(relay: origin, owner_id: owner, agent_secret: secret,
                                    linked_at: ISO8601DateFormatter().string(from: .now)))
    }

    public func linkCode() async throws -> String {
        let result = try await authorized("/agent/link-codes")
        guard let code = result["code"] as? String else { throw RelayFailure("The relay returned no link code.") }
        return code
    }

    public func grants() async throws -> String {
        let result = try await authorized("/agent/grants", method: "GET")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public func revoke(id: String? = nil) async throws {
        let route = id.map { "/agent/grants/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)" } ?? "/agent/grants"
        _ = try await authorized(route, method: "DELETE")
    }

    public func unlink() async throws {
        do { _ = try await authorized("/agent/owner", method: "DELETE") }
        catch let error as RelayFailure where error.status == 401 { /* already forgotten */ }
        try credentials.remove()
    }

    /// Polls until cancelled. Only the two strict read-only library calls can
    /// reach the transcript store, and each response uses the MCP helper's code.
    public func run(onState: @escaping @Sendable (String) -> Void) async throws {
        guard let link = try credentials.read() else { throw RelayFailure("This Mac is not linked to a Scribe relay yet.") }
        var failures = 0
        while !Task.isCancelled {
            do {
                let result = try await request(origin: link.relay, route: "/agent/poll", secret: link.agent_secret)
                onState("connected")
                failures = 0
                for call in result["requests"] as? [[String: Any]] ?? [] {
                    guard let id = call["id"] as? String, let method = call["method"] as? String,
                          let raw = call["args"] as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: raw),
                          let args = try? JSONDecoder().decode([String: Value].self, from: data) else { continue }
                    var response = ScribeServer.relayAnswer(method: method, args: args, library: library)
                    response["id"] = .string(id)
                    let body = try JSONEncoder().encode(response)
                    _ = try await request(origin: link.relay, route: "/agent/responses", secret: link.agent_secret, body: body)
                }
            } catch {
                if Task.isCancelled { break }
                if let failure = error as? RelayFailure, failure.status == 401 {
                    throw RelayFailure("The relay no longer recognizes this Mac. It was unlinked; link it again from Scribe.", status: 401)
                }
                let delay = [1, 2, 5, 10, 30][min(failures, 4)]
                failures += 1
                onState("Relay unavailable (\(error.localizedDescription)). Retrying in \(delay)s.")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func authorized(_ route: String, method: String = "POST") async throws -> [String: Any] {
        guard let link = try credentials.read() else { throw RelayFailure("This Mac is not linked to a Scribe relay yet.") }
        return try await request(origin: link.relay, route: route, method: method, secret: link.agent_secret)
    }

    private func request(origin: String, route: String, method: String = "POST", secret: String? = nil,
                         body: Data? = nil) async throws -> [String: Any] {
        guard let url = URL(string: origin + route) else { throw RelayFailure("Invalid relay address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 65
        request.httpBody = body
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RelayFailure("The relay gave no HTTP response.") }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            throw RelayFailure(value["error"] as? String ?? "Relay answered \(response.statusCode).", status: response.statusCode)
        }
        return value
    }
}

private final class RelayNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
