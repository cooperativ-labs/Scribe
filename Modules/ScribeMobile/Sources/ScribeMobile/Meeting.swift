import Foundation

public struct Meeting: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case recording, importing, ready, preparing, transcribing, diarizing, paused, complete, failed
        public var isProcessing: Bool { [.preparing, .transcribing, .diarizing].contains(self) }
    }
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var state: State
    public var sourceFilename: String
    public var duration: Double?
    public var notice: String?
    public var turns: [Turn]
    public var speakerNames: [String: String]
    public var schemaVersion = 1

    public init(id: UUID = UUID(), title: String, sourceFilename: String, state: State = .ready) {
        self.id = id; self.title = title; self.createdAt = Date()
        self.sourceFilename = sourceFilename; self.state = state
        turns = []; speakerNames = [:]
    }

    public var speakerIDs: [String] {
        var seen = Set<String>()
        return turns.compactMap(\.speakerID).filter { seen.insert($0).inserted }
    }
    public func speakerName(_ id: String?) -> String {
        guard let id else { return "Unknown speaker" }
        return speakerNames[id] ?? "Speaker \((speakerIDs.firstIndex(of: id) ?? 0) + 1)"
    }
    /// Explicit export allowlist: never serializes source filenames, paths, audio, or embeddings.
    public var transcriptText: String {
        ([title, ""] + turns.map { "[\(Self.timecode($0.start))] \(speakerName($0.speakerID)): \($0.text)" }).joined(separator: "\n")
    }
    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

public struct Turn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var speakerID: String?
    public var overlaps: Bool
    public init(start: Double, end: Double, text: String, speakerID: String?, overlaps: Bool = false) {
        id = UUID(); self.start = start; self.end = end; self.text = text
        self.speakerID = speakerID; self.overlaps = overlaps
    }
}

public enum MobileError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}
