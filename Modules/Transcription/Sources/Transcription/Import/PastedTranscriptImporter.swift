import CryptoKit
import Foundation
import ScribeAppCore

public enum TranscriptImportFormat: String, CaseIterable, Identifiable, Sendable {
    case fireflies
    public var id: String { rawValue }
    public var displayName: String { "Fireflies" }
}

public struct PastedTranscriptImportError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Fireflies supplies turn starts, not word timings or recording duration.
/// Keep its text and labels verbatim; mark all derived end times as estimates.
public enum PastedTranscriptParser {
    public static func parse(_ text: String, format: TranscriptImportFormat, title: String, now: Date = Date()) throws -> CanonicalTranscript {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PastedTranscriptImportError(message: "Enter a transcript title.") }
        let header = try NSRegularExpression(pattern: #"^(.+?)\s+\((\d{1,6}:\d{2}(?::\d{2})?)\):\s*(.*)$"#)
        var turns: [(name: String, start: Int, text: String)] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = header.firstMatch(in: line, range: range) {
                func field(_ n: Int) -> String { String(line[Range(match.range(at: n), in: line)!]) }
                let parts = field(2).split(separator: ":").compactMap { Int($0) }
                guard parts.dropFirst().allSatisfy({ $0 < 60 }) else {
                    throw PastedTranscriptImportError(message: "Invalid timestamp on line \(index + 1). Use MM:SS or HH:MM:SS.")
                }
                let start = parts.reduce(0) { $0 * 60 + $1 } * 1_000
                guard turns.last.map({ start >= $0.start }) ?? true else {
                    throw PastedTranscriptImportError(message: "Timestamps must be in order (line \(index + 1)).")
                }
                turns.append((field(1).trimmingCharacters(in: .whitespaces), start, field(3)))
            } else {
                // Refuse a malformed turn header instead of silently assigning it
                // to the preceding speaker. Plain wrapped text stays with its turn.
                guard !turns.isEmpty, !line.contains("):") else {
                    throw PastedTranscriptImportError(message: "Unrecognized Fireflies turn on line \(index + 1). Expected Speaker (MM:SS): Text.")
                }
                turns[turns.count - 1].text += "\n" + line
            }
        }
        guard !turns.isEmpty else { throw PastedTranscriptImportError(message: "Paste a Fireflies transcript to import.") }
        guard turns.allSatisfy({ !$0.name.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PastedTranscriptImportError(message: "Every turn needs a speaker and text.")
        }
        var speakers: [TranscriptSpeaker] = []
        var ids: [String: String] = [:]
        for turn in turns where ids[turn.name] == nil {
            let id = "speaker_\(speakers.count + 1)"
            ids[turn.name] = id
            speakers.append(TranscriptSpeaker(id: id, identityAssignment: .unmatched, labelSnapshot: turn.name))
        }
        let segments = turns.enumerated().map { index, turn in
            TranscriptSegment(
                id: String(format: "segment_%06d", index + 1), speakerID: ids[turn.name], speakerLabel: turn.name,
                startMs: turn.start, endMs: index + 1 < turns.count ? max(turn.start + 1, turns[index + 1].start) : turn.start + 1_000,
                text: turn.text, overlap: false, timingQuality: .segmentOnly
            )
        }
        let transcript = CanonicalTranscript(
            transcriptID: UUID().uuidString, revision: 1, title: title, status: .completeWithWarnings,
            createdAt: ISO8601DateFormatter().string(from: now),
            source: TranscriptSource(filename: "Fireflies transcript.txt", durationMs: segments.map(\.endMs).max()!,
                                     checksum: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()),
            language: "und", languageSource: .unknown, speakers: speakers, segments: segments,
            processingOptions: ["import_format": .string(format.rawValue)],
            warnings: [TranscriptWarning(code: "import_estimated_timing", message: "Imported from Fireflies without audio. Turn end times and duration are estimated; the last turn is assigned one second.")]
        )
        try CanonicalTranscriptValidator.validate(transcript)
        return transcript
    }
}

public protocol PastedTranscriptImporting: Sendable {
    func importTranscript(_ text: String, format: TranscriptImportFormat, title: String) throws -> TranscriptReviewFile
}

public struct StoredPastedTranscriptImporter: PastedTranscriptImporting {
    public let store: TranscriptStore
    public init(store: TranscriptStore) { self.store = store }

    public func importTranscript(_ text: String, format: TranscriptImportFormat, title: String) throws -> TranscriptReviewFile {
        let transcript = try PastedTranscriptParser.parse(text, format: format, title: title)
        let runID = UUID()
        let meeting = store.storeDirectoryURL.appending(path: SourceSnapshotService.meetingDirectoryPrefix + runID.uuidString)
        let staging = store.storeDirectoryURL.appending(path: ".import-\(runID.uuidString)")
        let runDirectory = meeting.appending(path: "runs/\(runID.uuidString)")
        let stagedRun = staging.appending(path: "runs/\(runID.uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(at: stagedRun, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        // This absent audio path deliberately uses the existing no-audio gates.
        let audioURL = meeting.appending(path: "source.m4a")
        let job = TranscriptionJob(
            runID: runID, request: TranscriptionRequest(sourceURL: audioURL, modelProfileID: "import:fireflies", title: transcript.title),
            sourceSnapshotURL: audioURL, runDirectoryURL: runDirectory,
            sourceFingerprint: transcript.source.checksum, modelFingerprint: "import:fireflies",
            configurationFingerprint: "import:fireflies:1", state: .complete
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let writer = AtomicReplaceFileWriter()
        try writer.write(try encoder.encode(job), to: stagedRun.appending(path: "job.json"))
        try writer.write(try CanonicalTranscriptCodec.encode(transcript), to: stagedRun.appending(path: TranscriptRunArtifact.canonicalTranscript))
        try writer.write(Data(text.utf8), to: staging.appending(path: "imported-fireflies.txt"))
        try manager.moveItem(at: staging, to: meeting)
        return TranscriptReviewFile(StoredTranscriptRun(job: job, transcript: transcript))
    }
}
