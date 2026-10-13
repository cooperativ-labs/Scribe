import Combine
import AppKit
import Carbon.HIToolbox
import Foundation

public struct MessageDebugEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Level: String, Codable, Sendable { case status, warning, error, event }
    public let id: UUID
    public let timestamp: Date
    public let source: String
    public let level: Level
    public let message: String
    public let context: String?
}

/// Opt-in history of user-facing messages and the events that explain them.
/// Audio, live previews, dictated text and assistant source/answer text never
/// enter this API. Callers supply status copy only. Disk writes are serialized
/// off the main actor so capturing a warning cannot interrupt audio capture.
@MainActor
public final class MessageDebugLog: ObservableObject {
    public static let shared = MessageDebugLog()
    public static let defaultFileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/Debugging/messages.json")
    public static let enabledKey = "scribe.debugging.captureMessages"

    @Published public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { record("Message capture enabled", source: "Debugging", level: .event, context: Self.keyboardContext) }
            else { append("Message capture disabled", source: "Debugging", level: .event, context: nil) }
        }
    }
    @Published public private(set) var entries: [MessageDebugEntry] = []
    @Published public private(set) var storageError: String?
    public let fileURL: URL
    private let defaults: UserDefaults
    private let limit: Int
    private let now: () -> Date
    private let writer = DispatchQueue(label: "Scribe.message-debug-log", qos: .utility)
    private let launchID = UUID().uuidString

    public init(defaults: UserDefaults = .standard, fileURL: URL = MessageDebugLog.defaultFileURL,
                limit: Int = 1_000, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.fileURL = fileURL
        self.limit = max(1, limit)
        self.now = now
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64_000_000 else { throw CocoaError(.fileReadTooLarge) }
                entries = Array(try JSONDecoder().decode([MessageDebugEntry].self, from: Data(contentsOf: fileURL)).suffix(self.limit))
            } catch {
                storageError = "Could not read saved messages: \(error.localizedDescription)"
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        record("Scribe launched", source: "Debugging", level: .event,
               context: "version=\(version); macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); \(Self.keyboardContext)")
    }

    private static var keyboardContext: String {
        "secureKeyboardEntry=\(IsSecureEventInputEnabled()); frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")"
    }

    public func record(_ message: String, source: String, level: MessageDebugEntry.Level = .status, context: String? = nil) {
        guard isEnabled else { return }
        append(message, source: source, level: level, context: context)
    }

    private func append(_ message: String, source: String, level: MessageDebugEntry.Level, context: String?) {
        entries.append(MessageDebugEntry(id: UUID(), timestamp: now(), source: String(source.prefix(100)),
                                        level: level, message: String(message.prefix(8_000)),
                                        context: "launch=\(launchID)" + (context.map { "; \($0.prefix(2_000))" } ?? "")))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        persist()
    }

    public func clear() {
        entries.removeAll()
        persist()
    }

    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map {
            "\(formatter.string(from: $0.timestamp)) [\($0.level.rawValue)] \($0.source): \($0.message)" +
                ($0.context.map { "\n  \($0)" } ?? "")
        }.joined(separator: "\n\n")
    }

    /// A barrier for tests and explicit shutdown callers; recording never waits.
    public func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }

    private func persist() {
        let snapshot = entries
        let destination = fileURL
        writer.async { [weak self] in
            let failure: String?
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                failure = nil
            } catch {
                failure = "Could not save messages: \(error.localizedDescription)"
            }
            Task { @MainActor [weak self] in self?.storageError = failure }
        }
    }
}
