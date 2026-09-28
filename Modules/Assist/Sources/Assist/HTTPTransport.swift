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
    private let redirectPolicy = AssistantRedirectPolicy()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: redirectPolicy)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
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

/// A server must not turn an approved request into an HTTP request to another
/// machine. This also prevents an HTTPS provider from downgrading on redirect.
final class AssistantRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              let origin = response.url else {
            completionHandler(nil)
            return
        }
        let secure = destination.scheme?.lowercased() == "https"
        let localToLocal = origin.scheme?.lowercased() == "http" &&
            AssistProvider.customBaseURL(origin.absoluteString) != nil &&
            destination.scheme?.lowercased() == "http" &&
            AssistProvider.customBaseURL(destination.absoluteString) != nil
        completionHandler(secure || localToLocal ? request : nil)
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

/// Reads one wire format's server-sent events into a result.
protocol StreamDecoder {
    associatedtype Output
    /// The result once the response has completed, else nil.
    mutating func consume(_ line: String) throws -> Output?
    /// The stream closed without a completion event.
    func finish() throws -> Output
}

extension HTTPTransport {
    /// Sends a streamed request and decodes its events, turning every failure
    /// into a `ResponsesError` (cancellation aside) whatever the provider.
    func stream<Decoder: StreamDecoder>(_ request: URLRequest, decoder: Decoder) async throws -> Decoder.Output {
        let (response, lines): (HTTPURLResponse, AsyncThrowingStream<String, Error>)
        do {
            (response, lines) = try await self.lines(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResponsesError.transport(error.localizedDescription)
        }
        guard response.statusCode == 200 else {
            var body: [String] = []
            do {
                for try await line in lines { body.append(line) }
            } catch {}
            throw ResponsesError.http(status: response.statusCode, headers: response.lowercasedHeaders, body: body.joined(separator: "\n"))
        }
        var decoder = decoder
        do {
            for try await line in lines {
                try Task.checkCancellation()
                if let result = try decoder.consume(line) { return result }
            }
        } catch let error as ResponsesError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResponsesError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        return try decoder.finish()
    }

    /// A whole JSON response for the model lists and key checks, with a
    /// non-200 status reported as `ResponsesError.http`.
    func json(_ request: URLRequest) async throws -> Any {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ResponsesError.transport(error.localizedDescription)
        }
        guard response.statusCode == 200 else {
            throw ResponsesError.http(status: response.statusCode, headers: response.lowercasedHeaders, body: String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }
}

/// The payload of one server-sent `data:` line as a JSON object; nil for
/// `event:` lines, comments, blank separators and `[DONE]`.
func eventPayload(_ line: String) -> [String: Any]? {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
