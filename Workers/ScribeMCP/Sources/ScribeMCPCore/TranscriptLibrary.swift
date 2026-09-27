import Foundation
import MCP
import Transcription

/// A failure whose message is safe to show the assistant.
public struct LibraryError: Error, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
}

/// The read-only view of a transcript store that the MCP tools serve.
///
/// Runs come from `TranscriptStore.confinedCompletedRuns()`, Scribe's own
/// store model, so the helper reads exactly what the app reads. Offsets and
/// lengths count UTF-16 code units, as the Node server does, so a client can
/// page through either server with the same numbers.
public struct TranscriptLibrary: Sendable {
    public let store: TranscriptStore

    public init(store: TranscriptStore) {
        self.store = store
    }

    public struct ListRequest: Sendable {
        public var query = ""
        public var after: Date?
        public var before: Date?
        public var limit = 10
        public var offset = 0
        public init() {}
    }

    public struct GetRequest: Sendable {
        public var id: String
        public var offset = 0
        public var maxChars = 16_000
        public var revision: Int?
        public init(id: String) { self.id = id }
    }

    public func list(_ request: ListRequest) throws -> Value {
        let (runs, skipped) = try snapshot()
        var seen = Set<String>()
        let latest = runs.filter { seen.insert($0.meeting).inserted }
        let needle = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = latest.filter { run in
            let t = run.transcript
            if let date = Self.parseDate(t.createdAt) {
                if let after = request.after, date < after { return false }
                if let before = request.before, date >= before { return false }
            }
            return needle.isEmpty || ([Self.title(of: t)] + t.speakers.map(\.labelSnapshot) + t.segments.map(\.text))
                .contains { Self.find(needle, in: $0.lowercased()) != nil }
        }
        let page = matches.dropFirst(request.offset).prefix(request.limit).map { run -> Value in
            var result = Self.summary(run)
            if !needle.isEmpty, let match = run.transcript.segments.first(where: { Self.find(needle, in: $0.text.lowercased()) != nil }),
               let excerpt = Self.excerpt(match.text, needle: needle) {
                result["excerpt"] = .string(excerpt)
            }
            return .object(result)
        }
        let next = request.offset + request.limit
        return [
            "transcripts": .array(Array(page)),
            "total": .int(matches.count),
            "next_offset": next < matches.count ? .int(next) : .null,
            "skipped_runs": .int(skipped),
        ]
    }

    public func get(_ request: GetRequest) throws -> Value {
        let (runs, _) = try snapshot()
        guard let run = runs.first(where: { Self.id(of: $0) == request.id.lowercased() }) else {
            throw LibraryError("Transcript not found. List recent transcripts again; it may have been deleted or is still processing.")
        }
        if let revision = request.revision, revision != run.transcript.revision {
            throw LibraryError("Transcript changed. Restart retrieval at offset 0 with its new revision.")
        }
        let text = Array(Self.text(of: run.transcript).utf16)
        guard request.offset <= text.count else { throw LibraryError("Offset is beyond the end of this transcript.") }
        var end = min(request.offset + request.maxChars, text.count)
        // Never end a page between the two halves of a surrogate pair.
        if end < text.count, UTF16.isLeadSurrogate(text[end - 1]) { end -= 1 }
        var result = Self.summary(run)
        result["text"] = .string(String(decoding: text[request.offset..<end], as: UTF16.self))
        result["offset"] = .int(request.offset)
        result["total_chars"] = .int(text.count)
        result["next_offset"] = end < text.count ? .int(end) : .null
        result["warnings"] = .array(run.transcript.warnings.map { ["code": .string($0.code), "message": .string($0.message)] })
        return .object(result)
    }

    // MARK: - Private

    private func snapshot() throws -> (runs: [ConfinedTranscriptRun], skipped: Int) {
        do {
            return try store.confinedCompletedRuns()
        } catch ConfinedTranscriptStoreError.tooManyRuns {
            throw LibraryError("Library exceeds 10,000 runs. Select a smaller transcript folder.")
        } catch {
            throw LibraryError("Scribe transcript folder is unavailable. Check SCRIBE_TRANSCRIPTS_DIR and folder permissions.")
        }
    }

    private static func id(of run: ConfinedTranscriptRun) -> String {
        run.job.runID.uuidString.lowercased()
    }

    private static func title(of transcript: CanonicalTranscript) -> String {
        if let title = transcript.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return transcript.source.filename.split(separator: "/").last.map(String.init) ?? transcript.source.filename
    }

    private static func summary(_ run: ConfinedTranscriptRun) -> [String: Value] {
        let t = run.transcript
        let id = id(of: run)
        return [
            "id": .string(id),
            "title": .string(title(of: t)),
            "created_at": .string(t.createdAt),
            "processed_at": .string(run.job.createdAt.formatted(.iso8601)),
            "revision": .int(t.revision),
            "duration_ms": .int(t.source.durationMs),
            "language": .string(t.language),
            "status": .string(t.status.rawValue),
            "speakers": .array(t.speakers.map { .string($0.labelSnapshot) }),
            "url": .string("scribe://transcripts/\(id)"),
        ]
    }

    static func text(of transcript: CanonicalTranscript) -> String {
        let labels = Dictionary(transcript.speakers.map { ($0.id, $0.labelSnapshot) }, uniquingKeysWith: { _, last in last })
        return transcript.segments.map { segment in
            let speaker = segment.speakerID.flatMap { labels[$0] } ?? segment.speakerLabel
            return "[\(timecode(segment.startMs))–\(timecode(segment.endMs))] \(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func timecode(_ ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// Up to 80 code units before the match and 200 from it, on word boundaries,
    /// with an ellipsis where text was cut.
    private static func excerpt(_ string: String, needle: String) -> String? {
        let text = Array(string.utf16), length = needle.utf16.count
        guard let index = find(needle, in: string.lowercased()) else { return nil }
        let space = UInt16(UInt8(ascii: " "))
        let start = index <= 80 ? 0 : (text[(index - 80)...].firstIndex(of: space).map { $0 + 1 } ?? index)
        let end: Int
        if index + 200 >= text.count {
            end = text.count
        } else if let last = text[...(index + 200)].lastIndex(of: space), last > index + length {
            end = last
        } else {
            end = index + 200
        }
        return (start > 0 ? "…" : "") + String(decoding: text[start..<max(start, end)], as: UTF16.self) + (end < text.count ? "…" : "")
    }

    /// The UTF-16 offset of a literal match, as JavaScript's indexOf reports it.
    private static func find(_ needle: String, in text: String) -> Int? {
        let range = (text as NSString).range(of: needle, options: .literal)
        return range.location == NSNotFound ? nil : range.location
    }

    static func parseDate(_ string: String) -> Date? {
        ISO8601DateFormatter.internet.date(from: string) ?? ISO8601DateFormatter.fractional.date(from: string)
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let internet = ISO8601DateFormatter()
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
