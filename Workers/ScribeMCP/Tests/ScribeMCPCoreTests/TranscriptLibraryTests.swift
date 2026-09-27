import Foundation
import MCP
import Testing
import Transcription
@testable import ScribeMCPCore

/// The Swift counterpart of Integrations/scribe/test/store.test.js: the helper
/// keeps the Node server's filesystem boundary and paging guarantees.
struct TranscriptLibraryTests {
    final class Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "scribe-mcp-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var library: TranscriptLibrary { TranscriptLibrary(store: TranscriptStore(storeDirectoryURL: root)) }

        @discardableResult
        func add(meeting: String = UUID().uuidString, runID: UUID = UUID(), directory: String? = nil,
                 date: String = "2026-09-20T10:00:00Z", text: String = "Ship the project on Friday.",
                 revision: Int = 1, complete: Bool = true) throws -> (id: String, dir: URL) {
            let dir = root.appending(path: "meeting--\(meeting)/runs/\(directory ?? runID.uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let job = """
            {"schemaVersion":1,"id":"\(UUID().uuidString)","runID":"\(runID.uuidString)",
             "request":{"requestID":"\(UUID().uuidString)","sourceURL":"file:///must/not/be/read.wav","languageMode":"automatic",
                        "speakerCount":"automatic","speakerMatching":"enabled","modelProfileID":"parakeet-v3"},
             "sourceSnapshotURL":"file:///must/not/be/read.wav","runDirectoryURL":"file:///must/not/be/read/",
             "sourceFingerprint":"s","modelFingerprint":"m","configurationFingerprint":"c","state":"complete","checkpoints":[],
             "createdAt":"\(date)","updatedAt":"\(date)"}
            """
            try Data(job.utf8).write(to: dir.appending(path: "job.json"))
            if complete { try transcript(text: text, revision: revision, date: date).write(to: dir.appending(path: "canonical-transcript.json")) }
            return (runID.uuidString.lowercased(), dir)
        }

        func transcript(text: String, revision: Int, date: String = "2026-09-20T10:00:00Z") throws -> Data {
            try CanonicalTranscriptCodec.encode(CanonicalTranscript(
                transcriptID: UUID().uuidString, revision: revision, title: "Planning", status: .complete, createdAt: date,
                source: TranscriptSource(filename: "planning.wav", durationMs: 60_000, checksum: "sha"), language: "en",
                languageSource: .detected,
                speakers: [TranscriptSpeaker(id: "speaker_1", identityAssignment: .manual, labelSnapshot: "Updated name")],
                segments: [TranscriptSegment(id: "segment_1", speakerID: "speaker_1", speakerLabel: "Old name", startMs: 1000,
                                             endMs: 2000, text: text, overlap: false, timingQuality: .asrWord)]))
        }
    }

    func list(_ library: TranscriptLibrary, _ configure: (inout TranscriptLibrary.ListRequest) -> Void = { _ in }) throws -> [String: Value] {
        var request = TranscriptLibrary.ListRequest()
        configure(&request)
        return try library.list(request).objectValue ?? [:]
    }

    func get(_ library: TranscriptLibrary, _ id: String, offset: Int = 0, maxChars: Int = 16_000, revision: Int? = nil) throws -> [String: Value] {
        var request = TranscriptLibrary.GetRequest(id: id)
        request.offset = offset
        request.maxChars = maxChars
        request.revision = revision
        return try library.get(request).objectValue ?? [:]
    }

    @Test func latestRunPerSourceFiltersAndLiteralSearch() throws {
        let fixture = try Fixture()
        try fixture.add(meeting: "one", date: "2026-09-18T10:00:00Z", text: "Old transcript")
        // Historical stores name the run directory differently from job.runID.
        let current = try fixture.add(meeting: "one", directory: UUID().uuidString, date: "2026-09-20T10:00:00Z", text: "Literal [query] ships Friday.")
        try fixture.add(meeting: "one", date: "2026-09-21T10:00:00Z", complete: false)
        try fixture.add(meeting: "two", date: "2026-09-19T10:00:00Z")
        let library = fixture.library
        let page = try list(library) { $0.limit = 1 }
        #expect(page["total"] == .int(2))
        #expect(page["transcripts"]?.arrayValue?.first?.objectValue?["id"] == .string(current.id))
        #expect(page["next_offset"] == .int(1))
        #expect(page["skipped_runs"] == .int(1))
        #expect(try list(library) { $0.query = "[query]" }["total"] == .int(1))
        #expect(try list(library) { $0.query = "UPDATED NAME" }["total"] == .int(2))
        #expect(try list(library) { $0.query = "Old transcript" }["total"] == .int(0))
        #expect(try list(library) { $0.before = TranscriptLibrary.parseDate("2026-09-20T10:00:00Z") }["total"] == .int(1))
        let result = try get(library, current.id)
        #expect(result["text"]?.stringValue?.contains("00:00:01") == true)
        #expect(result["text"]?.stringValue?.contains("Updated name") == true)
        let encoded = ScribeServer.json(.object(result))
        #expect(!encoded.contains("Old name") && !encoded.contains("planning.wav") && !encoded.contains("must/not"))
    }

    @Test func pagingRevisionsCorruptFilesAndPathBoundaries() throws {
        let fixture = try Fixture()
        let current = try fixture.add(text: String(repeating: "A😀long meeting ", count: 4000))
        let library = fixture.library
        var offset: Int? = 0, combined = ""
        while let start = offset {
            let page = try get(library, current.id, offset: start, maxChars: 1234, revision: 1)
            let text = try #require(page["text"]?.stringValue)
            #expect(text.utf16.last.map { !UTF16.isLeadSurrogate($0) } ?? true)
            combined += text
            offset = page["next_offset"]?.intValue
        }
        #expect(combined == (try get(library, current.id, maxChars: 1_000_000)["text"]?.stringValue))

        try fixture.transcript(text: "Changed", revision: 2).write(to: current.dir.appending(path: "canonical-transcript.json"))
        #expect(throws: LibraryError("Transcript changed. Restart retrieval at offset 0 with its new revision.")) { try get(library, current.id, revision: 1) }
        #expect(throws: LibraryError.self) { try get(library, "../../etc/passwd") }
        #expect(throws: LibraryError("Offset is beyond the end of this transcript.")) { try get(library, current.id, offset: 999_999) }
        try Data("broken".utf8).write(to: current.dir.appending(path: "canonical-transcript.json"))
        #expect(try list(library)["total"] == .int(0))

        // Symlinks that leave the store are never followed.
        let outside = try Fixture()
        let other = try outside.add()
        let otherMeeting = other.dir.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "meeting--symlink"), withDestinationURL: otherMeeting)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "meeting--escaped"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: "meeting--escaped/runs"),
                                                   withDestinationURL: other.dir.deletingLastPathComponent())
        let inside = try fixture.add()
        try FileManager.default.removeItem(at: inside.dir.appending(path: "canonical-transcript.json"))
        try FileManager.default.createSymbolicLink(at: inside.dir.appending(path: "canonical-transcript.json"),
                                                   withDestinationURL: other.dir.appending(path: "canonical-transcript.json"))
        #expect(try list(library)["total"] == .int(0))
        #expect(throws: LibraryError("Scribe transcript folder is unavailable. Check SCRIBE_TRANSCRIPTS_DIR and folder permissions.")) {
            try TranscriptLibrary(store: TranscriptStore(storeDirectoryURL: fixture.root.appending(path: "missing"))).list(.init())
        }
    }

    @Test func oversizedFilesAreSkipped() throws {
        let fixture = try Fixture()
        try fixture.add()
        let (runs, skipped) = try fixture.library.store.confinedCompletedRuns(maximumFileBytes: 100)
        #expect(runs.isEmpty && skipped == 1)
    }

    @Test func argumentsAreValidatedLikeTheNodeSchemas() throws {
        let fixture = try Fixture()
        let run = try fixture.add()
        let library = fixture.library
        func call(_ name: String, _ arguments: [String: Value]) throws -> Value {
            try ScribeServer.call(name, arguments: arguments, library: library)
        }
        #expect(try call("scribe_recent_transcripts", ["limit": 1.0]).objectValue?["total"] == .int(1))
        #expect(try call("scribe_search_transcripts", ["query": "  friday  "]).objectValue?["total"] == .int(1))
        #expect(try call("fetch", ["id": .string(run.id.uppercased())]).objectValue?["id"] == .string(run.id))
        for (name, arguments) in [("scribe_recent_transcripts", ["limit": 51]), ("scribe_recent_transcripts", ["offset": 1.5] as [String: Value]),
                                  ("scribe_recent_transcripts", ["after": "2026-09-20"]), ("scribe_search_transcripts", ["query": " "]),
                                  ("scribe_get_transcript", ["id": "not-a-uuid"]), ("scribe_get_transcript", ["id": .string(run.id), "max_chars": 999])] {
            #expect(throws: ScribeServer.InvalidArguments.self) { try call(name, arguments) }
        }
    }

    @Test func relayAcceptsOnlyStrictReadOnlyCalls() throws {
        let fixture = try Fixture()
        let run = try fixture.add()
        let library = fixture.library
        #expect(ScribeServer.relayAnswer(method: "list", args: [:], library: library)["result"]?.objectValue?["total"] == 1)
        #expect(ScribeServer.relayAnswer(method: "get", args: ["id": .string(run.id)], library: library)["result"]?.objectValue?["text"]?.stringValue?.contains("Friday") == true)
        for (method, args) in [("delete", [:]), ("list", ["root": "/"]), ("list", ["limit": 5000]),
                               ("get", ["id": "../../etc/passwd"])] as [(String, [String: Value])] {
            let answer = ScribeServer.relayAnswer(method: method, args: args, library: library)
            #expect(answer["error"] != nil && answer["result"] == nil)
        }
    }
}

extension LibraryError: CustomStringConvertible {
    public var description: String { message }
}
