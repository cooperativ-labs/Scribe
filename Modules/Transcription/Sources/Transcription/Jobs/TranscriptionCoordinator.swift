import Foundation
import Vocabulary
import ScribeAppCore

/// Owns the persistent, capture-aware transcription queue.
///
/// Job records are authoritative and live in their transcript-store run
/// directories.  The queue index only preserves ordering; recovery scans the
/// store as well, so an interrupted or lost index cannot strand a run.
public actor TranscriptionCoordinator {
    public struct Configuration: Sendable {
        public let transcriptStoreURL: URL
        public let queueFileURL: URL
        /// Enable for the app's transcript store. Diagnostic callers can retain the worker input.
        public let removePreparedAudioOnCompletion: Bool

        public init(
            transcriptStoreURL: URL,
            queueFileURL: URL? = nil,
            removePreparedAudioOnCompletion: Bool = false
        ) {
            self.transcriptStoreURL = transcriptStoreURL
            self.queueFileURL = queueFileURL ?? transcriptStoreURL.appendingPathComponent(".transcription-queue.json")
            self.removePreparedAudioOnCompletion = removePreparedAudioOnCompletion
        }
    }

    public enum Event: Sendable, Equatable {
        case queued(TranscriptionJob)
        case stageStarted(TranscriptionJob)
        case checkpointCompleted(TranscriptionJob, TranscriptionJobState)
        case completed(TranscriptionJob)
        case cancelled(TranscriptionJob)
        case failed(TranscriptionJob, TranscriptionDiagnostic)
        case suspended(TranscriptionJob)
    }

    private struct PersistedQueue: Codable {
        let schemaVersion: Int
        let jobFileURLs: [URL]
    }

    private let configuration: Configuration
    private let canStartJob: @Sendable () async -> Bool
    private let scheduler: (any ProcessingScheduler)?
    private let stageRunner: any TranscriptionStageRunning
    private let snapshotService: SourceSnapshotService
    private let writer: AtomicReplaceFileWriter
    private let now: @Sendable () -> Date
    /// Read once at enqueue, including enabled packs and aliases. Actual
    /// snapshot content is authoritative; derived runs may preserve an older one.
    private let vocabularySnapshot: @Sendable () throws -> VocabularySnapshot
    nonisolated(unsafe) private let fileManager: FileManager

    private var jobs: [UUID: TranscriptionJob] = [:]
    private var queue: [UUID] = []
    private var activeJobID: UUID?
    private var cancellationRequested = Set<UUID>()
    private var suspensionRequested = Set<UUID>()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(
        configuration: Configuration,
        scheduler: (any ProcessingScheduler)? = nil,
        stageRunner: any TranscriptionStageRunning,
        writer: AtomicReplaceFileWriter = AtomicReplaceFileWriter(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        canStartJob: @escaping @Sendable () async -> Bool = { true },
        vocabularySnapshot: @escaping @Sendable () throws -> VocabularySnapshot = { .init(revision: nil, terms: []) }
    ) throws {
        self.configuration = configuration
        self.canStartJob = canStartJob
        self.scheduler = scheduler
        self.stageRunner = stageRunner
        self.snapshotService = SourceSnapshotService(storeDirectory: configuration.transcriptStoreURL, fileManager: fileManager, writer: writer)
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
        self.vocabularySnapshot = vocabularySnapshot
        try fileManager.createDirectory(at: configuration.transcriptStoreURL, withIntermediateDirectories: true)
        let indexed = try Self.readQueueIndex(at: configuration.queueFileURL, fileManager: fileManager)
        let discovered = Self.discoverRecoverableJobs(in: configuration.transcriptStoreURL, fileManager: fileManager)
        // Every indexed job also lives in a run directory, so discovery finds it
        // a second time; keep whichever copy was written last.
        var recoveredByID = Dictionary((indexed + discovered).map { ($0.id, $0) }) { first, second in
            second.updatedAt > first.updatedAt ? second : first
        }
        for id in recoveredByID.keys {
            guard var job = recoveredByID[id], !job.state.isTerminal else { continue }
            // A process that stopped while a stage was executing has no claim to
            // that incomplete stage.  Its previous checkpoints are durable;
            // resume starts at the first missing one.
            job.state = .queued
            job.failure = nil
            job.updatedAt = now()
            try Self.writePersisted(job, fileManager: fileManager, writer: writer)
            recoveredByID[id] = job
        }
        let recovered = recoveredByID.values.filter { !$0.state.isTerminal }.sorted { $0.createdAt < $1.createdAt }
        let recoveredJobFileURLs = recovered.map(\.jobFileURL)
        self.jobs = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
        self.queue = recovered.map(\.id)
        try Self.persistQueueIndex(recoveredJobFileURLs, to: configuration.queueFileURL, writer: writer)
    }

    public func events() -> AsyncStream<Event> {
        let token = UUID()
        return AsyncStream { continuation in
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    /// Snapshots a request source and creates an independent run directory.
    ///
    /// A request whose ID already has a persisted job — a recorder handoff
    /// published again after a crash, or drained twice — returns that job
    /// instead of allocating a second run. The source checksum is never the
    /// test: two recordings with identical audio are two requests.
    @discardableResult
    public func enqueue(_ request: TranscriptionRequest) throws -> TranscriptionJob {
        if let existing = persistedJob(forRequestID: request.requestID) { return existing }
        return try enqueue(request, snapshot: nil)
    }

    /// The job already recorded for a request ID, in memory or in the store.
    public func persistedJob(forRequestID requestID: UUID) -> TranscriptionJob? {
        if let live = jobs.values.first(where: { $0.request.requestID == requestID }) { return live }
        return Self.discoverRecoverableJobs(in: configuration.transcriptStoreURL, fileManager: fileManager)
            .filter { $0.request.requestID == requestID }
            .min { $0.createdAt < $1.createdAt }
    }

    private func enqueue(_ request: TranscriptionRequest, snapshot preserved: VocabularySnapshot?) throws -> TranscriptionJob {
        let vocabulary = try preserved ?? vocabularySnapshot()
        let importConfiguration = ImportConfiguration(
            modelProfileID: request.modelProfileID,
            languageMode: request.languageMode,
            expectedLanguage: request.expectedLanguage,
            speakerCount: request.speakerCount,
            speakerMatching: request.speakerMatching,
            microphoneSpeakerPrior: request.microphoneSpeakerPrior == true,
            speakerLibraryRevision: request.speakerLibraryRevision,
            vocabularyRevision: vocabulary.revision ?? request.vocabularyRevision
        )
        let fingerprint: ImportFingerprint
        let snapshot: SourceSnapshot
        do {
            fingerprint = try ImportFingerprint(fileAt: request.sourceURL, configuration: importConfiguration)
            snapshot = try snapshotService.createSnapshot(of: request.sourceURL, fingerprint: fingerprint)
        } catch {
            throw TranscriptionCoordinatorError.sourceSnapshotFailed(error.localizedDescription)
        }
        let runID = UUID()
        let runDirectory = snapshot.meetingDirectoryURL.appendingPathComponent("runs/\(runID.uuidString)", isDirectory: true)
        let modelFingerprint = FileContentHash.sha256(of: Data(request.modelProfileID.utf8))
        let job = TranscriptionJob(
            request: request,
            sourceSnapshotURL: snapshot.snapshotURL,
            runDirectoryURL: runDirectory,
            sourceFingerprint: fingerprint.contentHash,
            modelFingerprint: modelFingerprint,
            configurationFingerprint: fingerprint.configurationHash,
            createdAt: now(),
            updatedAt: now(),
            vocabularySnapshot: vocabulary
        )
        try write(job)
        jobs[job.id] = job
        queue.append(job.id)
        try persistQueueIndex()
        emit(.queued(job))
        return job
    }

    /// Restores queued work and turns interrupted non-terminal stages into a
    /// queued boundary.  Completed checkpoints stay intact and are never run
    /// again merely because the application terminated.
    @discardableResult
    public func recoverPendingJobs() throws -> [TranscriptionJob] {
        var recovered: [TranscriptionJob] = []
        let meetingDirectories = (try? fileManager.contentsOfDirectory(at: configuration.transcriptStoreURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for meeting in meetingDirectories where meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) {
            let runs = meeting.appendingPathComponent("runs", isDirectory: true)
            let runDirectories = (try? fileManager.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for run in runDirectories {
                let file = run.appendingPathComponent("job.json")
                guard var job = try? readJob(at: file), !job.state.isTerminal else { continue }
                job.state = .queued
                job.failure = nil
                job.updatedAt = now()
                try write(job)
                jobs[job.id] = job
                if !queue.contains(job.id) { queue.append(job.id) }
                recovered.append(job)
            }
        }
        try persistQueueIndex()
        for job in recovered { emit(.queued(job)) }
        return recovered
    }

    public func pendingJobs() -> [TranscriptionJob] { queue.compactMap { jobs[$0] } }
    public func job(id: UUID) -> TranscriptionJob? { jobs[id] }

    public func cancel(jobID: UUID) throws {
        guard var job = jobs[jobID] else { throw TranscriptionCoordinatorError.unknownJob(jobID) }
        guard !job.state.isTerminal else { return }
        if activeJobID == jobID {
            // A runner is allowed to finish its current atomic stage.  This flag
            // is consumed immediately afterwards, before another stage begins.
            cancellationRequested.insert(jobID)
            return
        }
        queue.removeAll { $0 == jobID }
        job.state = .cancelled
        job.updatedAt = now()
        jobs[jobID] = job
        try write(job)
        try persistQueueIndex()
        emit(.cancelled(job))
    }

    /// Creates a new run and copies only checkpoints whose source, model, and
    /// configuration fingerprints are exactly compatible with the old run.
    @discardableResult
    public func retry(jobID: UUID) throws -> TranscriptionJob {
        guard let previous = jobs[jobID] else { throw TranscriptionCoordinatorError.unknownJob(jobID) }
        let runID = UUID()
        let directory = previous.runDirectoryURL.deletingLastPathComponent().appendingPathComponent(runID.uuidString, isDirectory: true)
        let compatible = previous.checkpoints.filter { _, checkpoint in
            checkpoint.sourceFingerprint == previous.sourceFingerprint &&
            checkpoint.modelFingerprint == previous.modelFingerprint &&
            checkpoint.configurationFingerprint == previous.configurationFingerprint
        }
        let job = TranscriptionJob(
            request: previous.request,
            sourceSnapshotURL: previous.sourceSnapshotURL,
            runDirectoryURL: directory,
            sourceFingerprint: previous.sourceFingerprint,
            modelFingerprint: previous.modelFingerprint,
            configurationFingerprint: previous.configurationFingerprint,
            checkpoints: compatible,
            createdAt: now(),
            updatedAt: now(),
            retryOfRunID: previous.runID,
            vocabularySnapshot: previous.vocabularySnapshot
        )
        try write(job)
        try copySourceEnergy(from: previous, to: job)
        jobs[job.id] = job
        queue.append(job.id)
        try persistQueueIndex()
        emit(.queued(job))
        return job
    }

    /// Queues a fresh processing run over a retained source with a deliberate
    /// diarization constraint. Unlike `retry`, no checkpoint is copied: the
    /// configuration fingerprint changes with the speaker count, so reusing an
    /// ASR or diarization artifact could mix incompatible output. The prior run
    /// directory, including any review revisions, is never touched.
    @discardableResult
    ///
    /// `title` is the name the new run's transcript opens under; nil keeps the
    /// original request's title. The host passes the name a person gave the
    /// meeting, so a rerun does not revert a rename.
    public func reprocess(
        _ previous: TranscriptionJob,
        speakerCount: TranscriptionSpeakerCount,
        microphoneSpeakerPrior: Bool? = nil,
        title: String? = nil
    ) throws -> TranscriptionJob {
        let request = retainedSourceRequest(
            from: previous,
            speakerCount: speakerCount,
            speakerLibraryRevision: previous.request.speakerLibraryRevision,
            vocabularyRevision: previous.request.vocabularyRevision,
            modelProfileID: previous.request.modelProfileID,
            microphoneSpeakerPrior: microphoneSpeakerPrior,
            title: title
        )
        return try enqueueDerivedRun(from: previous, request: request, snapshot: previous.vocabularySnapshot ?? .init(revision: previous.request.vocabularyRevision, terms: []))
    }

    /// Queues a fresh run over a retained source with the host's current model
    /// profile and speaker-count setting. Vocabulary revision is left unset so
    /// enqueue records whatever glossary is in force now. No checkpoint is
    /// copied: a model or settings change must not mix with old ASR output.
    /// The prior run directory, including review revisions, is never touched.
    @discardableResult
    public func retranscribe(
        _ previous: TranscriptionJob,
        modelProfileID: String,
        speakerCount: TranscriptionSpeakerCount,
        microphoneSpeakerPrior: Bool? = nil,
        title: String? = nil
    ) throws -> TranscriptionJob {
        let request = retainedSourceRequest(
            from: previous,
            speakerCount: speakerCount,
            speakerLibraryRevision: nil,
            vocabularyRevision: nil,
            modelProfileID: modelProfileID,
            microphoneSpeakerPrior: microphoneSpeakerPrior,
            title: title
        )
        return try enqueueDerivedRun(from: previous, request: request)
    }

    private func retainedSourceRequest(
        from previous: TranscriptionJob,
        speakerCount: TranscriptionSpeakerCount,
        speakerLibraryRevision: String?,
        vocabularyRevision: String?,
        modelProfileID: String,
        microphoneSpeakerPrior: Bool?,
        title: String?
    ) -> TranscriptionRequest {
        // A fresh request ID: a rerun is a new request, not a replay. The
        // draft link is kept so the meeting's row and notes stay with it.
        TranscriptionRequest(
            sourceURL: previous.sourceSnapshotURL,
            languageMode: previous.request.languageMode,
            expectedLanguage: previous.request.expectedLanguage,
            speakerCount: speakerCount,
            speakerMatching: previous.request.speakerMatching,
            microphoneSpeakerPrior: microphoneSpeakerPrior ?? (previous.request.microphoneSpeakerPrior == true),
            recorderSessionDirectory: previous.request.recorderSessionDirectory
                ?? (previous.request.provenance != nil ? previous.request.sourceURL.deletingLastPathComponent() : nil),
            speakerLibraryRevision: speakerLibraryRevision,
            vocabularyRevision: vocabularyRevision,
            modelProfileID: modelProfileID,
            exportDirectory: previous.request.exportDirectory,
            provenance: previous.request.provenance,
            title: title ?? previous.request.title,
            draftID: previous.request.draftID
        )
    }

    private func enqueueDerivedRun(
        from previous: TranscriptionJob,
        request: TranscriptionRequest,
        snapshot: VocabularySnapshot? = nil
    ) throws -> TranscriptionJob {
        var job = try enqueue(request, snapshot: snapshot)
        job.retryOfRunID = previous.runID
        try copySourceEnergy(from: previous, to: job)
        try write(job)
        jobs[job.id] = job
        return job
    }

    private func copySourceEnergy(from previous: TranscriptionJob, to job: TranscriptionJob) throws {
        guard previous.sourceFingerprint == job.sourceFingerprint else { return }
        let source = previous.runDirectoryURL.appendingPathComponent(TranscriptRunArtifact.sourceEnergy)
        let target = job.runDirectoryURL.appendingPathComponent(TranscriptRunArtifact.sourceEnergy)
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { return }
        // An immutable source artifact survives recorder cleanup and fresh model runs.
        try fileManager.copyItem(at: source, to: target)
    }

    /// Drives at most one worker run at a time.  Starts are deferred while
    /// capture is active, and captures that start mid-run suspend at the next
    /// persisted stage boundary.
    public func runPending() async {
        guard activeJobID == nil else { return }
        while activeJobID == nil, let jobID = queue.first, var job = jobs[jobID] {
            guard await canStartJob(), activeJobID == nil else { return }
            if let scheduler, await scheduler.requestDeferral(for: ProcessingJobDescriptor(id: job.id, kind: "transcription")) == .deferUntilCaptureEnds {
                return
            }
            guard activeJobID == nil, queue.first == jobID else { return }
            queue.removeFirst()
            activeJobID = jobID
            let monitor = await beginMonitoringControlSignals(for: job)
            await execute(&job)
            monitor?.cancel()
            activeJobID = nil
            if let current = jobs[jobID], current.state == .queued, !queue.contains(jobID) {
                queue.append(jobID)
            }
            try? persistQueueIndex()
        }
    }

    private func execute(_ job: inout TranscriptionJob) async {
        for stage in TranscriptionJobState.processingStages {
            if cancellationRequested.remove(job.id) != nil {
                transition(&job, to: .cancelled)
                return
            }
            if suspensionRequested.remove(job.id) != nil {
                transition(&job, to: .queued)
                emit(.suspended(job))
                return
            }
            if let checkpoint = job.checkpoints[stage], isCompatible(checkpoint, with: job) { continue }

            transition(&job, to: stage)
            emit(.stageStarted(job))
            do {
                let output = try await stageRunner.run(stage: stage, job: job)
                job.checkpoints[stage] = TranscriptionStageCheckpoint(
                    stage: stage,
                    sourceFingerprint: job.sourceFingerprint,
                    modelFingerprint: job.modelFingerprint,
                    configurationFingerprint: job.configurationFingerprint,
                    artifactURL: output.artifactURL,
                    completedAt: now()
                )
                job.updatedAt = now()
                persist(job)
                emit(.checkpointCompleted(job, stage))
            } catch {
                let diagnostic = TranscriptionDiagnostic(code: "transcription.stage.\(stage.rawValue)", message: error.localizedDescription)
                job.failure = diagnostic
                transition(&job, to: .failed)
                emit(.failed(job, diagnostic))
                return
            }
        }
        if transition(&job, to: .complete), configuration.removePreparedAudioOnCompletion {
            removePreparedAudio(for: job)
        }
        emit(.completed(job))
    }

    private func removePreparedAudio(for job: TranscriptionJob) {
        let run = job.runDirectoryURL.resolvingSymlinksInPath()
        let runs = run.deletingLastPathComponent()
        let meeting = runs.deletingLastPathComponent()
        let source = job.sourceSnapshotURL.resolvingSymlinksInPath()
        let prepared = run.appending(path: TranscriptStore.preparedAudioFileName)
        guard UUID(uuidString: run.lastPathComponent) != nil,
              runs.lastPathComponent == "runs",
              meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix),
              meeting.deletingLastPathComponent().path == configuration.transcriptStoreURL.resolvingSymlinksInPath().path,
              source.deletingLastPathComponent().path == meeting.path,
              (try? prepared.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: run.appending(path: TranscriptRunArtifact.canonicalTranscript)),
              let transcript = try? CanonicalTranscriptCodec.decode(data),
              transcript.source.checksum == job.sourceFingerprint,
              let snapshot = try? FileContentHash.sha256(ofFileAt: source),
              snapshot.digest == job.sourceFingerprint else { return }

        // Cleanup is optional once the transcript is saved. A filesystem
        // error leaves the WAV available without affecting the completed run.
        try? fileManager.removeItem(at: prepared)
    }

    @discardableResult
    private func transition(_ job: inout TranscriptionJob, to state: TranscriptionJobState) -> Bool {
        job.state = state
        job.updatedAt = now()
        return persist(job)
    }

    private func beginMonitoringControlSignals(for job: TranscriptionJob) async -> Task<Void, Never>? {
        guard let scheduler else { return nil }
        let stream = await scheduler.jobControlSignals(for: job.id)
        return Task { [weak self] in
            for await signal in stream {
                await self?.receive(signal, for: job.id)
            }
        }
    }

    private func receive(_ signal: ProcessingJobControlSignal, for jobID: UUID) {
        switch signal {
        case .suspend: suspensionRequested.insert(jobID)
        case .resume:
            suspensionRequested.remove(jobID)
            Task { await self.runPending() }
        }
    }

    private func isCompatible(_ checkpoint: TranscriptionStageCheckpoint, with job: TranscriptionJob) -> Bool {
        checkpoint.sourceFingerprint == job.sourceFingerprint &&
        checkpoint.modelFingerprint == job.modelFingerprint &&
        checkpoint.configurationFingerprint == job.configurationFingerprint
    }

    private static func readQueueIndex(at queueFileURL: URL, fileManager: FileManager) throws -> [TranscriptionJob] {
        guard fileManager.fileExists(atPath: queueFileURL.path) else { return [] }
        let decoder = JSONDecoder()
        let index = try decoder.decode(PersistedQueue.self, from: Data(contentsOf: queueFileURL))
        return index.jobFileURLs.compactMap { file in
            guard let job = try? readPersistedJob(at: file), !job.state.isTerminal else { return nil }
            return job
        }
    }

    private static func discoverRecoverableJobs(in store: URL, fileManager: FileManager) -> [TranscriptionJob] {
        let meetings = (try? fileManager.contentsOfDirectory(at: store, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return meetings.flatMap { meeting -> [TranscriptionJob] in
            guard meeting.lastPathComponent.hasPrefix(SourceSnapshotService.meetingDirectoryPrefix) else { return [] }
            let runs = meeting.appendingPathComponent("runs", isDirectory: true)
            let runDirectories = (try? fileManager.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return runDirectories.compactMap { run in
                try? readPersistedJob(at: run.appendingPathComponent("job.json"))
            }
        }
    }

    private func readJob(at url: URL) throws -> TranscriptionJob {
        try Self.readPersistedJob(at: url)
    }

    private static func readPersistedJob(at url: URL) throws -> TranscriptionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptionJob.self, from: Data(contentsOf: url))
    }

    private func write(_ job: TranscriptionJob) throws {
        do {
            try Self.writePersisted(job, fileManager: fileManager, writer: writer)
        } catch {
            throw TranscriptionCoordinatorError.persistenceFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func persist(_ job: TranscriptionJob) -> Bool {
        jobs[job.id] = job
        return (try? write(job)) != nil
    }

    private func persistQueueIndex() throws {
        try Self.persistQueueIndex(queue.compactMap { jobs[$0]?.jobFileURL }, to: configuration.queueFileURL, writer: writer)
    }

    private static func writePersisted(_ job: TranscriptionJob, fileManager: FileManager, writer: AtomicReplaceFileWriter) throws {
        try fileManager.createDirectory(at: job.runDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let snapshot = job.vocabularySnapshot {
            try writer.write(encoder.encode(snapshot), to: job.runDirectoryURL.appendingPathComponent("vocabulary.json"))
        }
        try writer.write(encoder.encode(job), to: job.jobFileURL)
    }

    private static func persistQueueIndex(_ urls: [URL], to queueFileURL: URL, writer: AtomicReplaceFileWriter) throws {
        let index = PersistedQueue(schemaVersion: 1, jobFileURLs: urls)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer.write(encoder.encode(index), to: queueFileURL)
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ token: UUID) { continuations[token] = nil }
}
