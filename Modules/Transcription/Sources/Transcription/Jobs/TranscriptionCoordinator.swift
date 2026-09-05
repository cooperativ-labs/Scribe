import Foundation
import ScribeAppCore

/// The durable state of a transcription run.  The non-terminal cases are the
/// safe boundaries at which a run may be paused, cancelled, or recovered.
public enum TranscriptionJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case preparing
    case transcribing
    case reconcilingTimings
    case diarizing
    case assembling
    case matchingSpeakers
    case complete
    case cancelled
    case failed

    public var isTerminal: Bool {
        self == .complete || self == .cancelled || self == .failed
    }

    public static let processingStages: [Self] = [
        .preparing, .transcribing, .reconcilingTimings, .diarizing,
        .assembling, .matchingSpeakers,
    ]
}

/// Export failures are deliberately independent from the canonical transcript.
public enum TranscriptionExportState: String, Codable, Sendable, Equatable {
    case notRequested
    case queued
    case exporting
    case complete
    case failed
}

/// A completed stage's durable, fingerprinted recovery point.
public struct TranscriptionStageCheckpoint: Codable, Sendable, Equatable {
    public let stage: TranscriptionJobState
    public let sourceFingerprint: String
    public let modelFingerprint: String
    public let configurationFingerprint: String
    public let artifactURL: URL?
    public let completedAt: Date

    public init(
        stage: TranscriptionJobState,
        sourceFingerprint: String,
        modelFingerprint: String,
        configurationFingerprint: String,
        artifactURL: URL? = nil,
        completedAt: Date = Date()
    ) {
        self.stage = stage
        self.sourceFingerprint = sourceFingerprint
        self.modelFingerprint = modelFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.artifactURL = artifactURL
        self.completedAt = completedAt
    }
}

/// The result a stage runner writes after it has atomically committed its own
/// intermediate artifact.  The coordinator owns the matching job checkpoint.
public struct TranscriptionStageOutput: Sendable, Equatable {
    public let artifactURL: URL?

    public init(artifactURL: URL? = nil) {
        self.artifactURL = artifactURL
    }
}

/// The worker-facing seam.  Keeping it small lets the next WorkerClient
/// objective plug in without giving the worker responsibility for queue state.
public protocol TranscriptionStageRunning: Sendable {
    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput
}

/// The persisted contents of `<run>/job.json`.
public struct TranscriptionJob: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let runID: UUID
    public let request: TranscriptionRequest
    public let sourceSnapshotURL: URL
    public let runDirectoryURL: URL
    public let sourceFingerprint: String
    public let modelFingerprint: String
    public let configurationFingerprint: String
    public var state: TranscriptionJobState
    public var checkpoints: [TranscriptionJobState: TranscriptionStageCheckpoint]
    /// Keys are exporter names (for example `txt`, `json`, and `srt`).
    public var exportStates: [String: TranscriptionExportState]
    public var failure: TranscriptionDiagnostic?
    public let createdAt: Date
    public var updatedAt: Date
    public var retryOfRunID: UUID?

    public init(
        id: UUID = UUID(),
        runID: UUID = UUID(),
        request: TranscriptionRequest,
        sourceSnapshotURL: URL,
        runDirectoryURL: URL,
        sourceFingerprint: String,
        modelFingerprint: String,
        configurationFingerprint: String,
        state: TranscriptionJobState = .queued,
        checkpoints: [TranscriptionJobState: TranscriptionStageCheckpoint] = [:],
        exportStates: [String: TranscriptionExportState] = [:],
        failure: TranscriptionDiagnostic? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        retryOfRunID: UUID? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.runID = runID
        self.request = request
        self.sourceSnapshotURL = sourceSnapshotURL
        self.runDirectoryURL = runDirectoryURL
        self.sourceFingerprint = sourceFingerprint
        self.modelFingerprint = modelFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.state = state
        self.checkpoints = checkpoints
        self.exportStates = exportStates
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.retryOfRunID = retryOfRunID
    }

    public var jobFileURL: URL { runDirectoryURL.appendingPathComponent("job.json") }
}

public enum TranscriptionCoordinatorError: Error, Sendable, Equatable {
    case unknownJob(UUID)
    case sourceSnapshotFailed(String)
    case persistenceFailed(String)
}

/// Owns the persistent, capture-aware transcription queue.
///
/// Job records are authoritative and live in their transcript-store run
/// directories.  The queue index only preserves ordering; recovery scans the
/// store as well, so an interrupted or lost index cannot strand a run.
public actor TranscriptionCoordinator {
    public struct Configuration: Sendable {
        public let transcriptStoreURL: URL
        public let queueFileURL: URL

        public init(transcriptStoreURL: URL, queueFileURL: URL? = nil) {
            self.transcriptStoreURL = transcriptStoreURL
            self.queueFileURL = queueFileURL ?? transcriptStoreURL.appendingPathComponent(".transcription-queue.json")
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
        canStartJob: @escaping @Sendable () async -> Bool = { true }
    ) throws {
        self.configuration = configuration
        self.canStartJob = canStartJob
        self.scheduler = scheduler
        self.stageRunner = stageRunner
        self.snapshotService = SourceSnapshotService(storeDirectory: configuration.transcriptStoreURL, fileManager: fileManager, writer: writer)
        self.writer = writer
        self.fileManager = fileManager
        self.now = now
        try fileManager.createDirectory(at: configuration.transcriptStoreURL, withIntermediateDirectories: true)
        let indexed = try Self.readQueueIndex(at: configuration.queueFileURL, fileManager: fileManager)
        let discovered = Self.discoverRecoverableJobs(in: configuration.transcriptStoreURL, fileManager: fileManager)
        var recoveredByID = Dictionary(uniqueKeysWithValues: (indexed + discovered).map { ($0.id, $0) })
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
    @discardableResult
    public func enqueue(_ request: TranscriptionRequest) throws -> TranscriptionJob {
        let importConfiguration = ImportConfiguration(
            modelProfileID: request.modelProfileID,
            languageMode: request.languageMode,
            expectedLanguage: request.expectedLanguage,
            speakerCount: request.speakerCount,
            speakerMatching: request.speakerMatching,
            speakerLibraryRevision: request.speakerLibraryRevision
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
            updatedAt: now()
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
            exportStates: previous.exportStates.mapValues { $0 == .complete ? .complete : .notRequested },
            createdAt: now(),
            updatedAt: now(),
            retryOfRunID: previous.runID
        )
        try write(job)
        jobs[job.id] = job
        queue.append(job.id)
        try persistQueueIndex()
        emit(.queued(job))
        return job
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

    public func setExportState(_ state: TranscriptionExportState, named name: String, for jobID: UUID) throws {
        guard var job = jobs[jobID] else { throw TranscriptionCoordinatorError.unknownJob(jobID) }
        job.exportStates[name] = state
        job.updatedAt = now()
        jobs[jobID] = job
        try write(job)
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
        transition(&job, to: .complete)
        emit(.completed(job))
    }

    private func transition(_ job: inout TranscriptionJob, to state: TranscriptionJobState) {
        job.state = state
        job.updatedAt = now()
        persist(job)
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

    private func persist(_ job: TranscriptionJob) {
        jobs[job.id] = job
        try? write(job)
    }

    private func persistQueueIndex() throws {
        try Self.persistQueueIndex(queue.compactMap { jobs[$0]?.jobFileURL }, to: configuration.queueFileURL, writer: writer)
    }

    private static func writePersisted(_ job: TranscriptionJob, fileManager: FileManager, writer: AtomicReplaceFileWriter) throws {
        try fileManager.createDirectory(at: job.runDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
