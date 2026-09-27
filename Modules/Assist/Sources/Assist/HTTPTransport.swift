import Foundation

/// The network seam: URLSession in the app, recorded responses in tests.
public protocol HTTPTransport: Sendable {
    /// A whole response body.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A response body delivered line by line as it arrives, for server-sent events.
    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

extension HTTPURLResponse {
    /// Header values by lower-cased name.
    var lowercasedHeaders: [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return headers
    }
}

enum FormEncoding {
    static func encode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(pairs
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .utf8)
    }
}
