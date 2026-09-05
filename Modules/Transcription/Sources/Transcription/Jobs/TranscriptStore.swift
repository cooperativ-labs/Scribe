import Foundation
import ScribeAppCore

/// A run as review sees it: the job record, the source snapshot kept beside it,
/// and the canonical transcript when the run got far enough to produce one.
public struct StoredTranscriptRun: Sendable, Equatable, Identifiable {
    public let job: TranscriptionJob
    public let transcript: CanonicalTranscript?

    public var id: UUID { job.runID }
    public var runDirectoryURL: URL { job.runDirectoryURL }
    public var canonicalTranscriptURL: URL {
        job.runDirectoryURL.appending(path: TranscriptRunArtifact.canonicalTranscript)
    }

    public init(job: TranscriptionJob, transcript: CanonicalTranscript?) {
        self.job = job
        self.transcript = transcript
    }
}

/// Reads and writes the on-disk transcript store described in plan section 8.
///
/// The store is the authority on what exists, not an in-memory list: the
/// coordinator deliberately forgets terminal jobs, and a relaunch, a second
/// window, or an export must still find every completed run. Everything it
/// returns comes from files the coordinator and the stage runners committed.
public struct TranscriptStore: Sendable {
    public let storeDirectoryURL: URL
    private let writer: AtomicReplaceFileWriter
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        storeDirectoryURL: URL,
        writer: AtomicReplaceFileWriter = AtomicReplaceFileWriter(),
        fileManager: FileManager = .default
    ) {
        self.storeDirectoryURL = storeDirectoryURL
        self.writer = writer
        self.fileManager = fileManager
    }

    /// The user's default store location. Exports may go elsewhere; canonical
    /// data never does, which is what makes a read-only input folder workable.
    public static func defaultStoreDirectoryURL(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
    }

    /// Every run in the store, newest first.
    public func runs() -> [StoredTranscriptRun] {
        meetingDirectories().flatMap(runs(inMeetingAt:)).sorted { $0.job.createdAt > $1.job.createdAt }
    }

    /// The runs review should show: the newest run per source, so a rerun
    /// replaces its predecessor in the list without deleting it from the store.
    public func latestRunPerSource() -> [StoredTranscriptRun] {
        meetingDirectories().compactMap { meeting in
            runs(inMeetingAt: meeting).max { $0.job.createdAt < $1.job.createdAt }
        }
        .sorted { $0.job.createdAt > $1.job.createdAt }
    }

    public func run(withRunID runID: UUID) -> StoredTranscriptRun? {
        runs().first { $0.job.runID == runID }
    }

    public func transcript(forRunAt runDirectoryURL: URL) -> CanonicalTranscript? {
        let url = runDirectoryURL.appending(path: TranscriptRunArtifact.canonicalTranscript)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CanonicalTranscriptCodec.decode(data)
    }

    public func recognition(forRunAt runDirectoryURL: URL) -> SpeakerRecognitionRecord? {
        let url = runDirectoryURL.appending(path: TranscriptRunArtifact.speakerRecognition)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerRecognitionRecord.self, from: data)
    }

    /// Commits a new revision produced by review — a relabelling, never a
    /// reprocessing — beside the revision it supersedes.
    @discardableResult
    public func save(_ transcript: CanonicalTranscript, forRunAt runDirectoryURL: URL) throws -> URL {
        let url = runDirectoryURL.appending(path: TranscriptRunArtifact.canonicalTranscript)
        try writer.write(try CanonicalTranscriptCodec.encode(transcript), to: url)
        return url
    }

    /// Removes the meeting that produced this run: its source snapshot and every
    /// run made from it, not only the one review was showing.
    ///
    /// Review lists the newest run per source, so removing a single run would
    /// only resurface the one before it. A person deleting a transcript means
    /// the recording is done with, and that is the meeting directory.
    public func deleteMeeting(containingRunID runID: UUID) throws {
        guard let run = run(withRunID: runID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(runID.uuidString)")
        }
        // <store>/meeting--<source>/runs/<runID> → the meeting directory is two levels up.
        let meeting = run.runDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
        guard meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) else {
            throw TranscriptAssemblyError.missingArtifact("the meeting directory for \(runID.uuidString)")
        }
        try fileManager.removeItem(at: meeting)
    }

    /// The `TranscriptionResult` a completed run reports back to its caller.
    public func result(for run: StoredTranscriptRun) -> TranscriptionResult? {
        guard let transcript = run.transcript else { return nil }
        let status: TranscriptionResultStatus = switch transcript.status {
        case .complete: .complete
        case .completeWithWarnings: .completeWithWarnings
        case .noSpeech: .noSpeech
        }
        return TranscriptionResult(
            transcriptID: run.job.request.requestID,
            revision: transcript.revision,
            canonicalTranscriptURL: run.canonicalTranscriptURL,
            status: status
        )
    }

    // MARK: - Private

    private func meetingDirectories() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: storeDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) }
    }

    private func runs(inMeetingAt meeting: URL) -> [StoredTranscriptRun] {
        let runsDirectory = meeting.appending(path: "runs", directoryHint: .isDirectory)
        let contents = (try? fileManager.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.compactMap { runDirectory in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: runDirectory.appending(path: "job.json")),
                  let job = try? decoder.decode(TranscriptionJob.self, from: data) else { return nil }
            return StoredTranscriptRun(job: job, transcript: transcript(forRunAt: runDirectory))
        }
    }
}

public extension TranscriptReviewFile {
    /// Presents a stored run in the review window.
    ///
    /// The job state and the transcript are separate facts: a failed run with a
    /// committed transcript from an earlier revision still shows its transcript,
    /// with the failure reported above it.
    init(_ run: StoredTranscriptRun) {
        let recognitionURL = run.runDirectoryURL.appending(path: TranscriptRunArtifact.speakerRecognition)
        let suggestions = (try? Data(contentsOf: recognitionURL))
            .flatMap { try? JSONDecoder().decode(SpeakerRecognitionRecord.self, from: $0) }?
            .suggestions ?? []
        self.init(
            id: run.job.runID.uuidString,
            sourceSnapshotURL: run.job.sourceSnapshotURL,
            transcript: run.transcript,
            jobState: TranscriptJobState(run.job.state, transcript: run.transcript),
            processingError: run.job.failure?.message,
            suggestions: suggestions
        )
    }
}

public extension TranscriptJobState {
    /// Maps durable job state onto what review shows. The completed cases come
    /// from the transcript's own status, so "no speech" is not reported as a
    /// failure and warnings stay visible after the job record is forgotten.
    init(_ state: TranscriptionJobState, transcript: CanonicalTranscript?) {
        switch state {
        case .queued: self = .queued
        case .preparing, .transcribing, .reconcilingTimings, .diarizing, .assembling, .matchingSpeakers:
            self = .processing(progress: nil)
        case .cancelled: self = .failed(message: "This transcription was cancelled.")
        case .failed: self = .failed(message: "This transcription failed.")
        case .complete:
            self = switch transcript?.status {
            case .completeWithWarnings: .completeWithWarnings
            case .noSpeech: .noSpeech
            case .complete: .complete
            case nil: .failed(message: "This run completed without leaving a transcript.")
            }
        }
    }
}

/// Writes review revisions back into the run directory they came from.
///
/// Review identifies a file by its run ID, which is also the run directory's
/// name, so a revision is committed beside the run that produced it rather than
/// into whatever directory happened to be selected.
public struct TranscriptStoreRevisionWriter: TranscriptRevisionStoring {
    private let store: TranscriptStore

    public init(store: TranscriptStore) {
        self.store = store
    }

    public func save(_ transcript: CanonicalTranscript, forFileID fileID: TranscriptReviewFile.ID) throws {
        guard let runID = UUID(uuidString: fileID), let run = store.run(withRunID: runID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(fileID)")
        }
        try store.save(transcript, forRunAt: run.runDirectoryURL)
    }
}

/// Deletes a reviewed file by removing the meeting its run belongs to.
public struct TranscriptStoreFileDeleter: TranscriptFileDeleting {
    private let store: TranscriptStore

    public init(store: TranscriptStore) {
        self.store = store
    }

    public func delete(fileID: TranscriptReviewFile.ID) throws {
        guard let runID = UUID(uuidString: fileID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(fileID)")
        }
        try store.deleteMeeting(containingRunID: runID)
    }
}
