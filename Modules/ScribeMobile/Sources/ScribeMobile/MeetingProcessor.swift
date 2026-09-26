import Foundation
import ScribeInference

public protocol MeetingInference: Sendable {
    func transcribe(_ source: URL) async throws -> ParakeetAdapter.Transcript
    func diarize(_ source: URL) async throws -> OfflineDiarizationAdapter.Result
}

public struct LocalMeetingInference: MeetingInference {
    let manifest: ModelManifest
    let models: URL
    public init(manifest: ModelManifest, models: URL) { self.manifest = manifest; self.models = models }
    public func transcribe(_ source: URL) async throws -> ParakeetAdapter.Transcript {
        try await ParakeetAdapter(manifest: manifest, modelsDirectory: models).transcribe(fileURL: source)
    }
    public func diarize(_ source: URL) async throws -> OfflineDiarizationAdapter.Result {
        try await OfflineDiarizationAdapter(manifest: manifest, modelsDirectory: models).diarize(fileURL: source)
    }
}

public actor MeetingProcessor {
    private let store: MeetingStore
    private var active = false
    public init(store: MeetingStore) { self.store = store }
    public func run(id: UUID, inference: any MeetingInference,
                    progress: @Sendable (Meeting) async -> Void) async throws {
        guard !active else { throw MobileError.message("Another recording is being processed.") }
        active = true
        defer { active = false }
        var meeting = try await store.load(id)
        let directory = await store.directory(id)
        let prepared = directory.appending(path: "prepared.caf")
        do {
            try Task.checkCancellation()
            let hasPreparedAudio = await store.exists(id: id, name: "prepared.caf")
            if !(await store.exists(id: id, name: "prepared.json")) || !hasPreparedAudio {
                meeting.state = .preparing; meeting.notice = nil
                try await store.save(meeting); await progress(meeting)
                meeting.duration = try await AudioPreparation.prepare(source: store.sourceURL(meeting), destination: prepared)
                try await store.write(meeting.duration, id: id, name: "prepared.json")
                try await store.save(meeting)
            } else {
                meeting.duration = try await store.read(id: id, name: "prepared.json") as Double
            }
            try Task.checkCancellation()
            let transcript: ParakeetAdapter.Transcript
            if await store.exists(id: id, name: "asr.json") {
                transcript = try await store.read(id: id, name: "asr.json")
            } else {
                meeting.state = .transcribing
                try await store.save(meeting); await progress(meeting)
                transcript = try await inference.transcribe(prepared)
                // Save successful stage output even when cancellation arrived during Core ML execution.
                try await store.write(transcript, id: id, name: "asr.json")
            }
            try Task.checkCancellation()
            let diarization: OfflineDiarizationAdapter.Result
            if await store.exists(id: id, name: "diarization.json") {
                diarization = try await store.read(id: id, name: "diarization.json")
            } else {
                meeting.state = .diarizing
                try await store.save(meeting); await progress(meeting)
                diarization = try await inference.diarize(prepared)
                try await store.write(diarization, id: id, name: "diarization.json")
            }
            try Task.checkCancellation()
            meeting.turns = Self.assemble(transcript: transcript, diarization: diarization)
            meeting.state = .complete; meeting.notice = nil
            try await store.save(meeting); await progress(meeting)
            // Keep the original recording for playback; prepared PCM is reproducible.
            try? FileManager.default.removeItem(at: prepared)
            try? FileManager.default.removeItem(at: directory.appending(path: "prepared.json"))
        } catch {
            meeting.state = error is CancellationError ? .paused : .failed
            meeting.notice = error is CancellationError
                ? "Processing paused. Resume while Scribe is open; completed stages are saved."
                : error.localizedDescription
            try await store.save(meeting); await progress(meeting)
            throw error
        }
    }

    /// Conservative attribution: ambiguous overlap stays unknown, never assigns a person by guess.
    public static func assemble(transcript: ParakeetAdapter.Transcript,
                                diarization: OfflineDiarizationAdapter.Result) -> [Turn] {
        var turns: [Turn] = []
        for token in transcript.tokens {
            // Decoder punctuation can extend beyond the last voiced interval. It
            // belongs to the preceding words, not a new unknown-speaker turn.
            let surface = token.text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = turns.last, !surface.isEmpty,
               surface.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains),
               token.startSeconds - previous.end < 1.5 {
                turns[turns.count - 1].text += token.text
                turns[turns.count - 1].end = max(previous.end, token.endSeconds)
                continue
            }
            let midpoint = (token.startSeconds + token.endSeconds) / 2
            let candidates = diarization.intervals.filter { $0.startSeconds <= midpoint && $0.endSeconds > midpoint }
            let speakers = Set(candidates.map(\.speakerID))
            let overlap = speakers.count > 1 || candidates.contains(where: \.overlapsAnotherSpeaker)
            let speaker = !overlap && speakers.count == 1 ? speakers.first : nil
            if let last = turns.last, last.speakerID == speaker, last.overlaps == overlap,
               token.startSeconds - last.end < 1.5, token.endSeconds - last.start < 30 {
                turns[turns.count - 1].text += token.text
                turns[turns.count - 1].end = token.endSeconds
            } else {
                turns.append(Turn(start: token.startSeconds, end: token.endSeconds,
                                  text: token.text, speakerID: speaker, overlaps: overlap))
            }
        }
        return turns.map { turn in
            var turn = turn; turn.text = turn.text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return turn
        }.filter { !$0.text.isEmpty }
    }
}
