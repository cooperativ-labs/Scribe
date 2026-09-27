import Foundation
import Logging
import MCP

/// Wraps the stdio transport for two things the SDK's server leaves out:
///
/// - It adds `ScribeServer.serverInfoExtras` to the initialize result, since
///   `Server` cannot be given an icon or website.
/// - When stdin closes, it ends the stream only after every request already
///   read has been answered. The server handles each request in its own task
///   and stops when the stream ends, so a client that writes its requests and
///   closes stdin would otherwise get no answers.
public actor ServerInfoTransport: Transport {
    private let inner: any Transport
    private var initialized = false
    private var outstanding = 0
    private var drained: [CheckedContinuation<Void, Never>] = []
    public nonisolated let logger = Logger(label: "scribe-mcp", factory: { _ in SwiftLogNoOpLogHandler() })

    public init(_ inner: any Transport) {
        self.inner = inner
    }

    public func connect() async throws { try await inner.connect() }
    public func disconnect() async { await inner.disconnect() }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        let inner = inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await inner.receive() {
                        self.countRequests(in: data)
                        continuation.yield(data)
                    }
                    await self.waitUntilAnswered()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ data: Data) async throws {
        let object = try? JSONSerialization.jsonObject(with: data)
        defer { answered(Self.messages(in: object).filter { $0["method"] == nil && $0["id"] != nil }.count) }
        let message = object as? [String: Any]
        guard !initialized, var message, var result = message["result"] as? [String: Any],
              var info = result["serverInfo"] as? [String: Any] else {
            return try await inner.send(data)
        }
        initialized = true
        info.merge(ScribeServer.serverInfoExtras) { current, _ in current }
        result["serverInfo"] = info
        message["result"] = result
        try await inner.send(JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]))
    }

    private static func messages(in object: Any?) -> [[String: Any]] {
        object as? [[String: Any]] ?? (object as? [String: Any]).map { [$0] } ?? []
    }

    private func countRequests(in data: Data) {
        let messages = Self.messages(in: try? JSONSerialization.jsonObject(with: data))
        outstanding += messages.filter { $0["method"] != nil && $0["id"] != nil }.count
    }

    private func answered(_ count: Int) {
        guard count > 0 else { return }
        outstanding = max(0, outstanding - count)
        if outstanding == 0 {
            drained.forEach { $0.resume() }
            drained = []
        }
    }

    private func waitUntilAnswered() async {
        guard outstanding > 0 else { return }
        await withCheckedContinuation { drained.append($0) }
    }
}
