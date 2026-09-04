import Foundation
import ScribeAppCore

/// Host-side artifacts the worker does not produce, read back from a run directory.
///
/// The worker owns `prepare`, `transcribe`, `diarize`, and `embed`; the host owns
/// `reconcilingTimings` and `assembling`. Both halves communicate only through
/// files committed in the run directory, which is what lets a job resume after a
/// crash without repeating a finished stage.
public enum TranscriptRunArtifact {
    /// The worker's prepared-audio record.
    public static let prepare = "prepare.json"
    /// The worker's raw ASR output, decoded as `WorkerASRTranscript`.
    public static let workerTranscript = "transcript.json"
    public static let diarization = "diarization.json"
    public static let embeddings = "embeddings.json"
    /// The host's reconciled word list.
    public static let words = "words.json"
    /// The canonical transcript.
    ///
    /// Section 8 names this file `transcript.json`, but the worker's committed
    /// ASR checkpoint already holds that name in the same directory. Renaming a
    /// checkpoint an installed worker writes would invalidate every recorded
    /// checkpoint, so the canonical document takes the adjacent name instead.
    public static let canonicalTranscript = "canonical-transcript.json"
}

/// The worker's `prepare.json`, read for the decoded duration and rate.
struct PreparedAudioRecord: Codable, Sendable {
    let preparedAudioPath: String
    let sourceDurationSeconds: TimeInterval
    let sampleRate: Int
    let channels: Int
}

/// The worker's `diarization.json`.
struct DiarizationRecord: Codable, Sendable {
    struct Interval: Codable, Sendable {
        let speakerID: String
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let qualityScore: Float
        let overlapsAnotherSpeaker: Bool
    }

    let intervals: [Interval]
    let sourceDurationSeconds: TimeInterval
}

/// The host's committed `words.json`: reconciled words plus the warnings that
/// reconciliation raised, so `assembling` can resume without redoing the work.
struct ReconciledWordsRecord: Codable, Sendable {
    struct Word: Codable, Sendable {
        let id: String
        let text: String
        let startMs: Int?
        let endMs: Int?
        let enclosingStartMs: Int
        let enclosingEndMs: Int
    }

    let words: [Word]
    let droppedDuplicateTokenCount: Int
    let warnings: [TranscriptWarning]
}

public enum TranscriptAssemblyError: Error, LocalizedError, Equatable {
    case missingArtifact(String)
    case unreadableArtifact(String, String)

    public var errorDescription: String? {
        switch self {
        case let .missingArtifact(name):
            "The transcription helper did not leave \(name) in this run directory."
        case let .unreadableArtifact(name, reason):
            "\(name) could not be read: \(reason)"
        }
    }
}

/// Turns committed worker artifacts into a canonical transcript.
///
/// This is the `hostStageRunner` seam `WorkerStageRunner` documents: the helper
/// owns model execution, and the two stages that are pure host logic —
/// reconstructing word timings and building chronological speaker turns — run
/// here, in process, against files the helper already committed. Each stage
/// writes exactly one artifact and the coordinator records the checkpoint, so a
/// cancelled or crashed job resumes at the first stage whose artifact is absent.
public struct TranscriptAssemblyStageRunner: TranscriptionStageRunning {
    private let reconciler: TokenTimingReconciler
    private let turnBuilder: SpeakerTurnBuilder
    private let writer: AtomicReplaceFileWriter
    private let engineRevisions: [String: String]
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        reconciler: TokenTimingReconciler = TokenTimingReconciler(),
        turnBuilder: SpeakerTurnBuilder = SpeakerTurnBuilder(),
        engineRevisions: [String: String] = [:],
        writer: AtomicReplaceFileWriter = AtomicReplaceFileWriter(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reconciler = reconciler
        self.turnBuilder = turnBuilder
        self.engineRevisions = engineRevisions
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
    }

    public func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        switch stage {
        case .reconcilingTimings: try reconcileTimings(for: job)
        case .assembling: try assemble(for: job)
        default: TranscriptionStageOutput()
        }
    }

    // MARK: - Stages

    private func reconcileTimings(for job: TranscriptionJob) throws -> TranscriptionStageOutput {
        let prepared: PreparedAudioRecord = try read(TranscriptRunArtifact.prepare, in: job)
        let workerTranscript: WorkerASRTranscript = try read(TranscriptRunArtifact.workerTranscript, in: job)

        // The helper decodes to 16 kHz mono starting at the source's own zero, so
        // the working timeline is the source timeline. A future preparation stage
        // that trims or offsets writes its own mapping here instead.
        let mapping = AudioTimeMapping(sourceSampleRate: Double(prepared.sampleRate), workingSampleRate: 16_000)
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: workerTranscript,
            timeMapping: mapping,
            sourceDurationMs: milliseconds(prepared.sourceDurationSeconds)
        ))

        let record = ReconciledWordsRecord(
            words: result.words.map {
                ReconciledWordsRecord.Word(
                    id: $0.id, text: $0.text, startMs: $0.startMs, endMs: $0.endMs,
                    enclosingStartMs: $0.enclosingStartMs, enclosingEndMs: $0.enclosingEndMs
                )
            },
            droppedDuplicateTokenCount: result.droppedDuplicateTokenCount,
            warnings: result.warnings
        )
        return TranscriptionStageOutput(artifactURL: try write(record, named: TranscriptRunArtifact.words, in: job))
    }

    private func assemble(for job: TranscriptionJob) throws -> TranscriptionStageOutput {
        let prepared: PreparedAudioRecord = try read(TranscriptRunArtifact.prepare, in: job)
        let reconciled: ReconciledWordsRecord = try read(TranscriptRunArtifact.words, in: job)
        let diarization: DiarizationRecord = try read(TranscriptRunArtifact.diarization, in: job)

        let sourceDurationMs = milliseconds(prepared.sourceDurationSeconds)
        let words = reconciled.words.map {
            RecognizedWord(
                id: $0.id, text: $0.text, startMs: $0.startMs, endMs: $0.endMs,
                enclosingStartMs: $0.enclosingStartMs, enclosingEndMs: $0.enclosingEndMs
            )
        }
        // Intervals are clamped into the source duration and dropped when empty:
        // a diarizer boundary a few milliseconds past the decoded end must not
        // fail an otherwise complete transcript.
        let turns = diarization.intervals.compactMap { interval -> DiarizedSpeakerTurn? in
            let start = max(0, milliseconds(interval.startSeconds))
            let end = min(sourceDurationMs, milliseconds(interval.endSeconds))
            guard start < end else { return nil }
            return DiarizedSpeakerTurn(speakerID: interval.speakerID, startMs: start, endMs: end)
        }

        var warnings = reconciled.warnings
        let build: SpeakerTurnBuildResult
        if turns.isEmpty, !words.isEmpty {
            // Recognized speech with no usable diarization is a labelled-transcript
            // failure, not a transcript failure: the words are kept and every
            // segment stays explicitly unknown rather than being attributed.
            warnings.append(TranscriptWarning(
                code: "transcription.diarization.noSpeakers",
                message: "Speaker separation produced no usable speakers, so this transcript has no speaker labels."
            ))
            build = try turnBuilder.build(words: words, diarizedTurns: [])
        } else {
            build = try turnBuilder.build(words: words, diarizedTurns: turns)
        }
        for diagnostic in build.diagnostics {
            guard case let .untranscribedSpeech(startMs, endMs) = diagnostic else { continue }
            warnings.append(TranscriptWarning(
                code: "transcription.turns.untranscribedSpeech",
                message: "Speech between \(TranscriptTimecode.string(fromMilliseconds: startMs)) and \(TranscriptTimecode.string(fromMilliseconds: endMs)) produced no recognized words."
            ))
        }

        let transcript = CanonicalTranscript(
            transcriptID: job.runID.uuidString,
            revision: 1,
            status: build.segments.isEmpty ? .noSpeech : (warnings.isEmpty ? .complete : .completeWithWarnings),
            createdAt: ISO8601DateFormatter().string(from: now()),
            source: TranscriptSource(
                filename: job.request.sourceURL.lastPathComponent,
                durationMs: sourceDurationMs,
                checksum: job.sourceFingerprint
            ),
            // Detection is not part of the pinned engine yet; claiming a detected
            // language the recognizer never reported would be worse than saying so.
            language: job.request.expectedLanguage ?? "und",
            languageSource: job.request.expectedLanguage == nil ? .unknown : .userProvided,
            speakers: build.speakers,
            segments: build.segments,
            processingOptions: [
                "model_profile_id": .string(job.request.modelProfileID),
                "speaker_matching": .string(job.request.speakerMatching.rawValue),
                "configuration_fingerprint": .string(job.configurationFingerprint),
            ],
            engineRevisions: engineRevisions,
            warnings: warnings
        )
        return TranscriptionStageOutput(artifactURL: try write(transcript, named: TranscriptRunArtifact.canonicalTranscript, in: job))
    }

    // MARK: - Artifacts

    private func read<Value: Decodable>(_ name: String, in job: TranscriptionJob) throws -> Value {
        let url = job.runDirectoryURL.appending(path: name)
        guard fileManager.fileExists(atPath: url.path) else { throw TranscriptAssemblyError.missingArtifact(name) }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw TranscriptAssemblyError.unreadableArtifact(name, error.localizedDescription)
        }
    }

    private func write<Value: Encodable>(_ value: Value, named name: String, in job: TranscriptionJob) throws -> URL {
        let url = job.runDirectoryURL.appending(path: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer.write(try encoder.encode(value), to: url)
        return url
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }
}
