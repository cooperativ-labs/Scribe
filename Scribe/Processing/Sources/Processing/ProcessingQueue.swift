import Foundation
import ScribeAppCore

/// The durable, capture-aware owner of offline processing work.
///
/// The queue stores only session addresses.  Audio is always reconstructed from
/// `capture/` when a job runs, so an interrupted pass has no mutable checkpoint
/// to trust and can never damage the archive.  Its queue file is a convenience
/// for ordering work; `recoverSessions(in:)` also discovers manifests directly
/// so losing that file cannot strand a recoverable recording.
public actor ProcessingQueue: ProcessingScheduler {
    public struct Configuration: Sendable {
        public let queueFileURL: URL

        public init(queueFileURL: URL) {
            self.queueFileURL = queueFileURL
        }

        public static func inRecordingsDirectory(_ directory: URL) -> Configuration {
            Configuration(queueFileURL: directory.appendingPathComponent(".scribe-processing-queue.json"))
        }
    }

    public struct QueuedJob: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let sessionDirectory: URL

        public init(id: UUID, sessionDirectory: URL) {
            self.id = id
            self.sessionDirectory = sessionDirectory
        }
    }

    /// What the queue did with a job.
    ///
    /// Published because background progress is shown separately from capture:
    /// without an end-of-job fact the menu can only ever add rows, and a failure
    /// that left the originals intact would never reach the person.
    public enum Event: Sendable, Equatable {
        case queued(QueuedJob)
        case started(QueuedJob)
        case completed(QueuedJob)
        /// The originals are untouched; a previously published final file, if
        /// any, is still the one described by the manifest.
        case failed(QueuedJob, message: String)
    }

    private struct PersistedQueue: Codable {
        var version = 1
        var jobs: [QueuedJob]
    }

    private let configuration: Configuration
    private let processor: SessionProcessor
    private var jobs: [QueuedJob]
    private var runningJobID: UUID?
    private var captureActive = false
    private var signalContinuations: [UUID: [UUID: AsyncStream<ProcessingJobControlSignal>.Continuation]] = [:]
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(configuration: Configuration, processor: SessionProcessor = SessionProcessor()) throws {
        self.configuration = configuration
        self.processor = processor
        if FileManager.default.fileExists(atPath: configuration.queueFileURL.path) {
            let data = try Data(contentsOf: configuration.queueFileURL)
            self.jobs = try JSONDecoder().decode(PersistedQueue.self, from: data).jobs
        } else {
            self.jobs = []
        }
    }

    /// Observes queue outcomes. A subscriber sees only what happens after it
    /// subscribes; durable truth stays in the queue file and the manifests.
    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    /// Adds a completed-capture session to durable work. Duplicate requests are
    /// idempotent, which lets launch recovery and the UI both submit it safely.
    @discardableResult
    public func enqueue(sessionDirectory: URL, jobID: UUID) throws -> ProcessingJobDeferral {
        if !jobs.contains(where: { $0.id == jobID || $0.sessionDirectory.standardizedFileURL == sessionDirectory.standardizedFileURL }) {
            let job = QueuedJob(id: jobID, sessionDirectory: sessionDirectory)
            jobs.append(job)
            try persist()
            emit(.queued(job))
        }
        return captureActive ? .deferUntilCaptureEnds : .startNow
    }

    /// Starts at most one job. Calling this whenever capture becomes idle is
    /// intentional: it makes the throttle point explicit and keeps capture
    /// callbacks free of DSP and disk work.
    public func runPending() async {
        guard !captureActive, runningJobID == nil, let job = jobs.first else { return }
        runningJobID = job.id
        emit(.started(job))
        do {
            try processor.markRunning(sessionDirectory: job.sessionDirectory)
            let processor = processor
            _ = try await Task.detached(priority: .utility) {
                try processor.run(sessionDirectory: job.sessionDirectory)
            }.value
            jobs.removeAll { $0.id == job.id }
            try persist()
            emit(.completed(job))
        } catch {
            // SessionProcessor has already recorded `.failed` atomically. Keep
            // the failed work out of the automatic queue; a user/tool rerun is an
            // explicit new attempt and preserves any previously good final file.
            jobs.removeAll { $0.id == job.id }
            try? persist()
            // The same spelling `SessionProcessor` records in the manifest, so
            // the menu and the session's own error list agree.
            emit(.failed(job, message: String(describing: error)))
        }
        runningJobID = nil
        if !captureActive { await runPending() }
    }

    /// Capture wins over all background work. Existing jobs receive a cooperative
    /// suspension request; the recorder pipeline starts no new work until resume.
    public func setCaptureActive(_ active: Bool) async {
        guard captureActive != active else { return }
        captureActive = active
        let signal: ProcessingJobControlSignal = active ? .suspend : .resume
        for continuations in signalContinuations.values {
            for continuation in continuations.values { continuation.yield(signal) }
        }
        if !active { await runPending() }
    }

    /// Requeues durable work after an app crash. A manifest left `.running` is
    /// reset to `.pending` *before* it can execute, and the next pass rebuilds
    /// entirely from originals.
    @discardableResult
    public func recoverSessions(in recordingsDirectory: URL) throws -> [QueuedJob] {
        let manager = FileManager.default
        let candidates = try manager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var recovered: [QueuedJob] = []
        for directory in candidates {
            let metadata = directory.appendingPathComponent("metadata.json")
            guard manager.fileExists(atPath: metadata.path),
                  let manifest = try? RecorderSessionManifestCodec.decode(Data(contentsOf: metadata)),
                  manifest.capture.state != .capturing,
                  manifest.processing.state == .pending || manifest.processing.state == .running else { continue }
            if manifest.processing.state == .running {
                try processor.markPending(sessionDirectory: directory)
            }
            let job = QueuedJob(id: manifest.sessionID, sessionDirectory: directory)
            if !jobs.contains(where: { $0.id == job.id || $0.sessionDirectory.standardizedFileURL == directory.standardizedFileURL }) {
                jobs.append(job)
                recovered.append(job)
            }
        }
        try persist()
        for job in recovered { emit(.queued(job)) }
        return recovered
    }

    public func isCaptureActive() async -> Bool { captureActive }

    /// A snapshot for UI status and recovery tests; mutating the queue still goes
    /// through `enqueue`, `runPending`, and capture-state transitions.
    public func pendingJobs() -> [QueuedJob] { jobs }

    public func requestDeferral(for job: ProcessingJobDescriptor) async -> ProcessingJobDeferral {
        captureActive ? .deferUntilCaptureEnds : .startNow
    }

    public func jobControlSignals(for jobID: UUID) async -> AsyncStream<ProcessingJobControlSignal> {
        let token = UUID()
        return AsyncStream { continuation in
            signalContinuations[jobID, default: [:]][token] = continuation
            if captureActive { continuation.yield(.suspend) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSignal(token: token, for: jobID) }
            }
        }
    }

    private func emit(_ event: Event) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func removeEventContinuation(_ id: UUID) { eventContinuations[id] = nil }

    private func removeSignal(token: UUID, for jobID: UUID) {
        signalContinuations[jobID]?[token] = nil
        if signalContinuations[jobID]?.isEmpty == true { signalContinuations[jobID] = nil }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicReplaceFileWriter().write(encoder.encode(PersistedQueue(jobs: jobs)), to: configuration.queueFileURL)
    }
}

/// The single session-processing transaction shared by the UI queue and
/// `scribe-process`. Each phase writes only verified temporaries; final manifest
/// replacement is the last state transition of that phase.
public struct SessionProcessor: Sendable {
    public init() {}

    @discardableResult
    public func run(sessionDirectory: URL) throws -> MixdownResult {
        try markRunning(sessionDirectory: sessionDirectory)
        do {
            _ = try UnprocessedFLACExporter().export(sessionDirectory: sessionDirectory)
            return try MixdownService().run(sessionDirectory: sessionDirectory)
        } catch {
            try? markFailed(sessionDirectory: sessionDirectory, error: error)
            throw error
        }
    }

    public func markRunning(sessionDirectory: URL) throws {
        try replaceProcessingState(in: sessionDirectory, with: .running, error: nil)
    }

    public func markPending(sessionDirectory: URL) throws {
        try replaceProcessingState(in: sessionDirectory, with: .pending, error: nil)
    }

    private func markFailed(sessionDirectory: URL, error: Error) throws {
        try replaceProcessingState(in: sessionDirectory, with: .failed, error: error)
    }

    private func replaceProcessingState(in sessionDirectory: URL, with state: ProcessingState, error: Error?) throws {
        let manifestURL = sessionDirectory.appendingPathComponent("metadata.json")
        let current = try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))
        var errors = current.processing.errors
        if let error {
            let record = ManifestError(code: "processing.pipeline", message: String(describing: error))
            errors.removeAll { $0.code == record.code }
            errors.append(record)
        }
        let processing = ProcessingMetadata(
            state: state,
            dependencyVersions: current.processing.dependencyVersions,
            configuration: current.processing.configuration,
            resamplingCorrections: current.processing.resamplingCorrections,
            delayCorrections: current.processing.delayCorrections,
            mixGains: current.processing.mixGains,
            errors: errors
        )
        let updated = RecorderSessionManifest(
            schemaVersion: current.schemaVersion, sessionID: current.sessionID,
            appBuild: current.appBuild, macOSVersion: current.macOSVersion,
            startedAt: current.startedAt, endedAt: current.endedAt,
            durationSeconds: current.durationSeconds, completionStatus: current.completionStatus,
            capture: current.capture, tracks: current.tracks, gaps: current.gaps,
            interruptions: current.interruptions, processing: processing
        )
        try AtomicReplaceFileWriter().write(updated, to: manifestURL)
    }
}
