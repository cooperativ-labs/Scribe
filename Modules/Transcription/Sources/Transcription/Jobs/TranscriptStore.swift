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

    /// The runs review should show: the newest completed transcript per source.
    /// While a reprocess is queued or running, keep its predecessor visible so
    /// the reviewer can continue using its saved edits; once the new run has a
    /// transcript it replaces the predecessor in the list without deleting it
    /// from the store.
    public func latestRunPerSource() -> [StoredTranscriptRun] {
        meetingDirectories().compactMap { meeting in
            let runs = runs(inMeetingAt: meeting)
            return runs.filter { $0.transcript != nil }.max { $0.job.createdAt < $1.job.createdAt }
                ?? runs.max { $0.job.createdAt < $1.job.createdAt }
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

    /// Removes the recording behind this run and keeps everything else: the
    /// source snapshot and the prepared audio each run decoded from it. The
    /// transcripts, their revisions, and the speaker records stay, so review
    /// still opens the meeting; it just has nothing left to play.
    ///
    /// Every run of the meeting shares the one snapshot, so a run still in
    /// flight would lose its input mid-stage; that is refused rather than raced.
    public func deleteAudio(containingRunID runID: UUID) throws {
        guard let run = run(withRunID: runID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(runID.uuidString)")
        }
        let meeting = run.runDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
        guard meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) else {
            throw TranscriptAssemblyError.missingArtifact("the meeting directory for \(runID.uuidString)")
        }
        let meetingRuns = runs(inMeetingAt: meeting)
        guard meetingRuns.allSatisfy(\.job.state.isTerminal) else { throw TranscriptStoreError.meetingInUse }
        for url in audioFiles(inMeetingAt: meeting, runs: meetingRuns) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Joins two recordings of one call into a single meeting.
    ///
    /// The second recording's audio is appended to the first's and the two
    /// saved transcripts are joined (`TranscriptRecordingCombiner`), so the
    /// edits made to either are kept and nothing is transcribed again. The
    /// result is a new meeting named after the joined audio's content, like
    /// any import, holding one completed run; both original meetings, with
    /// their run history, are then removed. That last step is what makes this
    /// irreversible.
    ///
    /// The new meeting is fully written before either original is touched, so
    /// a failure part way leaves both recordings as they were.
    ///
    /// - Returns: The combined run's ID, which is also its review file ID.
    @discardableResult
    public func combineRecordings(
        firstRunID: UUID,
        secondRunID: UUID,
        concatenator: AudioConcatenator = AudioConcatenator(),
        now: Date = Date()
    ) async throws -> UUID {
        let first = try combinable(runID: firstRunID)
        let second = try combinable(runID: secondRunID)
        guard first.meeting.standardizedFileURL != second.meeting.standardizedFileURL else {
            throw TranscriptStoreError.sameRecording
        }

        let staging = storeDirectoryURL.appending(path: ".combine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let snapshotName = "source.m4a"
        let stagedSource = staging.appending(path: snapshotName)
        let joined = try await concatenator.concatenate(
            [first.run.job.sourceSnapshotURL, second.run.job.sourceSnapshotURL],
            to: stagedSource
        )
        let hashed = try FileContentHash.sha256(ofFileAt: stagedSource)
        let sourceID = String(hashed.digest.prefix(32))
        let meeting = storeDirectoryURL.appending(path: SourceSnapshotService.meetingDirectoryPrefix + sourceID, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: meeting.path) else { throw TranscriptStoreError.combinedRecordingExists }

        let runID = UUID()
        let runDirectory = meeting.appending(path: "runs/\(runID.uuidString)", directoryHint: .isDirectory)
        let stagedRun = staging.appending(path: "runs/\(runID.uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: stagedRun, withIntermediateDirectories: true)

        // What review shows for each side, inferred speakers included, since
        // the per-recording diarization they come from is not carried over.
        let firstTranscript = UnknownFragmentReconciler.applied(to: first.transcript, in: first.run.runDirectoryURL) ?? first.transcript
        let secondTranscript = UnknownFragmentReconciler.applied(to: second.transcript, in: second.run.runDirectoryURL) ?? second.transcript
        let combined = TranscriptRecordingCombiner.combine(
            first: firstTranscript,
            firstSuggestions: recognition(forRunAt: first.run.runDirectoryURL)?.suggestions ?? [],
            second: secondTranscript,
            secondSuggestions: recognition(forRunAt: second.run.runDirectoryURL)?.suggestions ?? [],
            offsetMs: joined.offsetsMs.count > 1 ? joined.offsetsMs[1] : firstTranscript.source.durationMs,
            source: TranscriptSource(filename: firstTranscript.source.filename, durationMs: joined.durationMs, checksum: hashed.digest)
        )
        try CanonicalTranscriptValidator.validate(combined.transcript)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let previous = first.run.job
        let sourceURL = meeting.appending(path: snapshotName)
        // A combined recording has no recorder session behind it, so the
        // session's per-track evidence must not be read on a later rerun.
        let request = TranscriptionRequest(
            sourceURL: sourceURL,
            languageMode: previous.request.languageMode,
            expectedLanguage: previous.request.expectedLanguage,
            speakerCount: previous.request.speakerCount,
            speakerMatching: previous.request.speakerMatching,
            speakerLibraryRevision: previous.request.speakerLibraryRevision,
            vocabularyRevision: previous.request.vocabularyRevision,
            modelProfileID: previous.request.modelProfileID,
            exportDirectory: previous.request.exportDirectory,
            title: previous.request.title
        )
        let job = TranscriptionJob(
            runID: runID,
            request: request,
            sourceSnapshotURL: sourceURL,
            runDirectoryURL: runDirectory,
            sourceFingerprint: hashed.digest,
            modelFingerprint: previous.modelFingerprint,
            configurationFingerprint: previous.configurationFingerprint,
            state: .complete,
            createdAt: previous.createdAt,
            updatedAt: now,
            vocabularySnapshot: previous.vocabularySnapshot
        )
        try writer.write(try encoder.encode(job), to: stagedRun.appending(path: "job.json"))
        try writer.write(try CanonicalTranscriptCodec.encode(combined.transcript), to: stagedRun.appending(path: TranscriptRunArtifact.canonicalTranscript))
        if !combined.suggestions.isEmpty {
            let record = SpeakerRecognitionRecord(
                libraryRevision: recognition(forRunAt: first.run.runDirectoryURL)?.libraryRevision,
                suggestions: combined.suggestions
            )
            try writer.write(try encoder.encode(record), to: stagedRun.appending(path: TranscriptRunArtifact.speakerRecognition))
        }

        let snapshots = SourceSnapshotService(storeDirectory: storeDirectoryURL)
        let originals = [first.meeting, second.meeting].compactMap(snapshots.readRecord(in:))
        let record = SourceSnapshotRecord(
            schemaVersion: SourceSnapshotRecord.currentSchemaVersion,
            sourceID: sourceID,
            contentHash: hashed.digest,
            byteCount: hashed.byteCount,
            snapshotFileName: snapshotName,
            originalPaths: originals.flatMap(\.originalPaths),
            configurationHashes: [previous.configurationFingerprint],
            createdAt: now,
            updatedAt: now
        )
        try writer.write(try encoder.encode(record), to: staging.appending(path: SourceSnapshotRecord.fileName))

        try fileManager.moveItem(at: staging, to: meeting)
        try fileManager.removeItem(at: first.meeting)
        try fileManager.removeItem(at: second.meeting)
        return runID
    }

    /// The run, its meeting, and its saved transcript, when it can be combined.
    private func combinable(runID: UUID) throws -> (run: StoredTranscriptRun, meeting: URL, transcript: CanonicalTranscript) {
        guard let run = run(withRunID: runID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(runID.uuidString)")
        }
        let meeting = run.runDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
        guard meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) else {
            throw TranscriptAssemblyError.missingArtifact("the meeting directory for \(runID.uuidString)")
        }
        guard runs(inMeetingAt: meeting).allSatisfy(\.job.state.isTerminal) else { throw TranscriptStoreError.meetingInUse }
        guard let transcript = run.transcript else { throw TranscriptStoreError.noTranscript }
        guard fileManager.fileExists(atPath: run.job.sourceSnapshotURL.path) else { throw TranscriptStoreError.audioDeleted }
        return (run, meeting, transcript)
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
            guard let data = try? Data(contentsOf: runDirectory.appending(path: "job.json")),
                  let job = try? Self.decodeJob(data) else { return nil }
            return StoredTranscriptRun(job: job, transcript: transcript(forRunAt: runDirectory))
        }
    }

    /// `source` or `source.<ext>` beside the import sidecar, and each run's
    /// `prepared.wav`. Only Scribe's own names are matched, so nothing a person
    /// put in the meeting folder is touched.
    private func audioFiles(inMeetingAt meeting: URL, runs: [StoredTranscriptRun]) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: meeting,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let sources = contents.filter {
            let name = $0.lastPathComponent
            return (name == "source" || name.hasPrefix("source.")) && !$0.hasDirectoryPath
        }
        let prepared = runs
            .map { $0.runDirectoryURL.appending(path: Self.preparedAudioFileName) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        return sources + prepared
    }

    /// The worker's decoded copy of the source, written into each run directory.
    static let preparedAudioFileName = "prepared.wav"

    private static func decodeJob(_ data: Data) throws -> TranscriptionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: data)
    }
}

public enum TranscriptStoreError: LocalizedError, Equatable, Sendable {
    /// Another run of the same meeting is still queued or running.
    case meetingInUse
    /// Combining needs a finished transcript on both sides.
    case noTranscript
    /// Combining needs both recordings; one has been deleted.
    case audioDeleted
    /// Both runs belong to the same meeting.
    case sameRecording
    /// The joined audio is identical to a recording already in the store.
    case combinedRecordingExists

    public var errorDescription: String? {
        switch self {
        case .meetingInUse: "A transcription of this recording is still running. Try again once it finishes."
        case .noTranscript: "Only recordings with a finished transcript can be combined."
        case .audioDeleted: "The audio for one of these recordings has been deleted, so they can no longer be combined."
        case .sameRecording: "These are the same recording."
        case .combinedRecordingExists: "These recordings have already been combined."
        }
    }
}

// MARK: - Confined reading

/// A completed run read through `TranscriptStore.confinedCompletedRuns()`,
/// with the meeting directory it was found in. Only `meeting`, the job's
/// run ID and dates, and the transcript are trustworthy: the URLs recorded
/// inside job.json are never followed.
public struct ConfinedTranscriptRun: Sendable {
    public let meeting: String
    public let job: TranscriptionJob
    public let transcript: CanonicalTranscript
}

public enum ConfinedTranscriptStoreError: Error, Equatable, Sendable {
    case unavailable
    case tooManyRuns
}

public extension TranscriptStore {
    /// Every completed run, read the way a process serving the library to other
    /// programs must: only Scribe's own layout is walked, symlinks must resolve
    /// inside the store, files are opened without following a final symlink and
    /// capped in size, and paths recorded in job.json are ignored. Runs that are
    /// unfinished, unreadable or outside those rules are counted, not returned.
    /// Newest run first; ties by lowercase run ID.
    func confinedCompletedRuns(
        maximumRuns: Int = 10_000,
        maximumFileBytes: Int = 32 * 1024 * 1024
    ) throws -> (runs: [ConfinedTranscriptRun], skipped: Int) {
        guard let root = Self.realPath(storeDirectoryURL.path), Self.isDirectory(root),
              let meetings = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            throw ConfinedTranscriptStoreError.unavailable
        }
        var runs: [ConfinedTranscriptRun] = []
        var skipped = 0, count = 0
        for meeting in meetings.sorted()
        where meeting.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) && Self.isDirectory("\(root)/\(meeting)") {
            let folder = "\(root)/\(meeting)/runs"
            guard let resolved = Self.realPath(folder), resolved.hasPrefix(root + "/"),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                skipped += 1
                continue
            }
            for entry in entries.sorted() where !entry.hasPrefix(".") && Self.isDirectory("\(folder)/\(entry)") {
                count += 1
                if count > maximumRuns { throw ConfinedTranscriptStoreError.tooManyRuns }
                // The directory name must look like a run; job.runID stays the
                // identity, since historical stores name the directory differently.
                guard UUID(uuidString: entry) != nil,
                      let jobData = Self.readConfined("\(folder)/\(entry)/job.json", root: root, limit: maximumFileBytes),
                      let job = try? Self.decodeJob(jobData),
                      let data = Self.readConfined("\(folder)/\(entry)/\(TranscriptRunArtifact.canonicalTranscript)", root: root, limit: maximumFileBytes),
                      let transcript = try? CanonicalTranscriptCodec.decode(data) else {
                    skipped += 1
                    continue
                }
                runs.append(ConfinedTranscriptRun(meeting: meeting, job: job, transcript: transcript))
            }
        }
        runs.sort {
            $0.job.createdAt != $1.job.createdAt
                ? $0.job.createdAt > $1.job.createdAt
                : $0.job.runID.uuidString.lowercased() < $1.job.runID.uuidString.lowercased()
        }
        return (runs, skipped)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A real directory, not a symlink to one.
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func readConfined(_ path: String, root: String, limit: Int) -> Data? {
        guard let resolved = realPath(path), resolved.hasPrefix(root + "/") else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
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
            transcript: UnknownFragmentReconciler.applied(to: run.transcript, in: run.runDirectoryURL),
            jobState: TranscriptJobState(run.job.state, transcript: run.transcript),
            processingError: run.job.failure?.message,
            hasAudio: FileManager.default.fileExists(atPath: run.job.sourceSnapshotURL.path),
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

/// Deletes a reviewed file by removing the meeting its run belongs to, or
/// only the meeting's recording.
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

    public func deleteAudio(fileID: TranscriptReviewFile.ID) throws {
        guard let runID = UUID(uuidString: fileID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(fileID)")
        }
        try store.deleteAudio(containingRunID: runID)
    }
}

/// Combines two reviewed files by joining the meetings their runs belong to.
public struct TranscriptStoreRecordingCombiner: TranscriptRecordingCombining {
    private let store: TranscriptStore

    public init(store: TranscriptStore) {
        self.store = store
    }

    public func combine(firstFileID: TranscriptReviewFile.ID, secondFileID: TranscriptReviewFile.ID) async throws -> TranscriptReviewFile {
        guard let firstRunID = UUID(uuidString: firstFileID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(firstFileID)")
        }
        guard let secondRunID = UUID(uuidString: secondFileID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(secondFileID)")
        }
        let runID = try await store.combineRecordings(firstRunID: firstRunID, secondRunID: secondRunID)
        guard let run = store.run(withRunID: runID) else {
            throw TranscriptAssemblyError.missingArtifact("the run directory for \(runID.uuidString)")
        }
        return TranscriptReviewFile(run)
    }
}
