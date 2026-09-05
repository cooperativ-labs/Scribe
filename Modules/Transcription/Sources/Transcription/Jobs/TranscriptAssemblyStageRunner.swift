import Foundation
import ScribeAppCore
import Speakers

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
    /// Export-safe recognition decisions and review suggestions. Voice vectors
    /// stay in embeddings.json and the private speaker library.
    public static let speakerRecognition = "speaker-recognition.json"
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

struct WorkerSpeakerEmbeddingRecord: Codable, Sendable {
    let speakerID: String
    let vector: [Float]
    let modelID: String
    let modelRevision: String
    let preprocessingVersion: String
    let normalizationVersion: String
}

public struct SpeakerRecognitionRecord: Codable, Sendable, Equatable {
    public let libraryRevision: SpeakerLibraryRevision?
    public let suggestions: [TranscriptSpeakerSuggestion]

    public init(libraryRevision: SpeakerLibraryRevision?, suggestions: [TranscriptSpeakerSuggestion]) {
        self.libraryRevision = libraryRevision
        self.suggestions = suggestions
    }
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
    private let speakerLibrary: (any SpeakerLibrary)?
    private let identityMatcher: Speakers.SpeakerIdentityMatcher
    private let now: @Sendable () -> Date
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        reconciler: TokenTimingReconciler = TokenTimingReconciler(),
        turnBuilder: SpeakerTurnBuilder = SpeakerTurnBuilder(),
        speakerLibrary: (any SpeakerLibrary)? = nil,
        identityMatcher: Speakers.SpeakerIdentityMatcher = Speakers.SpeakerIdentityMatcher(
            configuration: SpeakerIdentityMatcherConfiguration(minimumConsistentExcerpts: 1)
        ),
        engineRevisions: [String: String] = [:],
        writer: AtomicReplaceFileWriter = AtomicReplaceFileWriter(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reconciler = reconciler
        self.turnBuilder = turnBuilder
        self.speakerLibrary = speakerLibrary
        self.identityMatcher = identityMatcher
        self.engineRevisions = engineRevisions
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
    }

    public func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        switch stage {
        case .reconcilingTimings: try reconcileTimings(for: job)
        case .assembling: try assemble(for: job)
        case .matchingSpeakers: try await matchSpeakers(for: job)
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

    private func matchSpeakers(for job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        let transcriptURL = job.runDirectoryURL.appending(path: TranscriptRunArtifact.canonicalTranscript)
        guard job.request.speakerMatching == .enabled, let speakerLibrary else {
            let record = SpeakerRecognitionRecord(libraryRevision: nil, suggestions: [])
            return TranscriptionStageOutput(artifactURL: try write(record, named: TranscriptRunArtifact.speakerRecognition, in: job))
        }

        let transcript: CanonicalTranscript = try read(TranscriptRunArtifact.canonicalTranscript, in: job)
        let embeddings: [WorkerSpeakerEmbeddingRecord] = try read(TranscriptRunArtifact.embeddings, in: job)
        let library = try await speakerLibrary.snapshot()
        let formatTransform = SpeakerPinnedEmbeddingFormat.transformVersion
        let assignments = embeddings.map { embedding in
            identityMatcher.match(
                RecordingLocalSpeaker(
                    speakerID: embedding.speakerID,
                    excerpts: [SpeakerEmbeddingExcerpt(
                        excerptID: "\(embedding.speakerID)-centroid",
                        vector: embedding.vector,
                        format: SpeakerEmbeddingFormat(
                            model: SpeakerEmbeddingModelIdentity(modelID: embedding.modelID, revision: embedding.modelRevision),
                            preprocessingVersion: embedding.preprocessingVersion,
                            normalizationVersion: embedding.normalizationVersion,
                            transformVersion: formatTransform
                        )
                    )]
                ),
                against: library
            )
        }
        let automatic: [String: SpeakerPersonRef] = Dictionary(uniqueKeysWithValues: assignments.compactMap { assignment -> (String, SpeakerPersonRef)? in
            guard assignment.outcome == .matched, let person = assignment.person else { return nil }
            return (assignment.recordingSpeakerID, person)
        })
        let suggestions = assignments.compactMap(TranscriptSpeakerSuggestion.init)

        if !automatic.isEmpty {
            let speakers = transcript.speakers.map { speaker -> TranscriptSpeaker in
                guard let person = automatic[speaker.id] else { return speaker }
                return TranscriptSpeaker(
                    id: speaker.id,
                    profileID: person.profileID.uuidString,
                    identityAssignment: .automatic,
                    labelSnapshot: person.displayName
                )
            }
            let labels: [String: String] = Dictionary(
                speakers.map { ($0.id, $0.labelSnapshot) },
                uniquingKeysWith: { first, _ in first }
            )
            let segments = transcript.segments.map { segment -> TranscriptSegment in
                guard let speakerID = segment.speakerID,
                      let label = labels[speakerID],
                      label != segment.speakerLabel else { return segment }
                return TranscriptSegment(
                    id: segment.id,
                    speakerID: segment.speakerID,
                    speakerLabel: label,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text,
                    overlap: segment.overlap,
                    timingQuality: segment.timingQuality,
                    speakerConfidence: segment.speakerConfidence,
                    words: segment.words
                )
            }
            let recognized = CanonicalTranscript(
                schemaVersion: transcript.schemaVersion,
                transcriptID: transcript.transcriptID,
                revision: transcript.revision,
                status: transcript.status,
                createdAt: transcript.createdAt,
                source: transcript.source,
                language: transcript.language,
                languageSource: transcript.languageSource,
                timestampUnit: transcript.timestampUnit,
                timestampOrigin: transcript.timestampOrigin,
                speakers: speakers,
                segments: segments,
                subtitleCueMappings: transcript.subtitleCueMappings,
                processingOptions: transcript.processingOptions.merging([
                    "speaker_library_revision": .string(library.revision.snapshotValue),
                    "speaker_matcher_version": .string(identityMatcher.configuration.matcherVersion),
                ]) { _, new in new },
                engineRevisions: transcript.engineRevisions,
                warnings: transcript.warnings
            )
            try writer.write(try CanonicalTranscriptCodec.encode(recognized), to: transcriptURL)
        }

        let record = SpeakerRecognitionRecord(libraryRevision: library.revision, suggestions: suggestions)
        return TranscriptionStageOutput(artifactURL: try write(record, named: TranscriptRunArtifact.speakerRecognition, in: job))
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
