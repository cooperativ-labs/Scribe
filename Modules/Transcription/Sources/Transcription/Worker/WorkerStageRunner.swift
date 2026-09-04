import Foundation
import ScribeAppCore

/// Drives the helper on behalf of `TranscriptionCoordinator`.
///
/// The helper runs one `run` operation covering `prepare`, `transcribe`,
/// `diarize`, and `embed`, emitting a committed checkpoint per stage. The
/// coordinator asks for one job stage at a time, so this runner keeps the
/// helper alive for the length of a job and hands each coordinator stage the
/// worker result it corresponds to. Stages the helper does not own —
/// timing reconciliation and turn assembly — are delegated to `hostStageRunner`
/// when the host provides one; that is the seam the transcription engine plugs
/// into.
public actor WorkerStageRunner: TranscriptionStageRunning {
    public struct Configuration: Sendable {
        public var installation: WorkerInstallation
        public var workingDirectoryURL: URL?
        public var environment: [String: String]
        public var responseTimeout: Duration

        public init(
            installation: WorkerInstallation,
            workingDirectoryURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            responseTimeout: Duration = .seconds(600)
        ) {
            self.installation = installation
            self.workingDirectoryURL = workingDirectoryURL
            self.environment = environment
            self.responseTimeout = responseTimeout
        }
    }

    /// Coordinator stages the helper performs, in the helper's own order.
    public static let workerStageNames: [TranscriptionJobState: String] = [
        .preparing: "prepare",
        .transcribing: "transcribe",
        .diarizing: "diarize",
        .matchingSpeakers: "embed",
    ]

    private struct Session {
        let client: WorkerClient
        let requestID: String
        let runDirectoryURL: URL
        var results: [String: WorkerStageResult] = [:]
        var finished = false
    }

    private let configuration: Configuration
    private let hostStageRunner: (any TranscriptionStageRunning)?
    private let eventHandler: (@Sendable (TranscriptionEvent) -> Void)?
    /// Extra `run` payload values; the integration test uses the helper's
    /// guarded deterministic mode through this.
    private let additionalRunOptions: [String: WorkerJSONValue]
    private var sessions: [UUID: Session] = [:]

    public init(
        configuration: Configuration,
        hostStageRunner: (any TranscriptionStageRunning)? = nil,
        additionalRunOptions: [String: WorkerJSONValue] = [:],
        eventHandler: (@Sendable (TranscriptionEvent) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.hostStageRunner = hostStageRunner
        self.eventHandler = eventHandler
        self.additionalRunOptions = additionalRunOptions
    }

    public func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        guard let workerStage = Self.workerStageNames[stage] else {
            emit(job, stage: stage.rawValue)
            guard let hostStageRunner else { return TranscriptionStageOutput() }
            return try await hostStageRunner.run(stage: stage, job: job)
        }
        do {
            let result = try await stageResult(named: workerStage, for: job)
            if workerStage == Self.workerStageNames[.matchingSpeakers] { try await finish(job) }
            let artifact = result.resultFileName.map { job.runDirectoryURL.appending(path: $0) }
            return TranscriptionStageOutput(artifactURL: artifact)
        } catch let failure as WorkerFailure {
            // Whatever the helper already committed stays on disk; the
            // coordinator keeps the checkpoints it recorded for those stages
            // and a retry resumes from them.
            await closeSession(for: job.id)
            emit(job, stage: workerStage, error: failure.diagnostic)
            throw failure
        }
    }

    /// Asks the helper running `jobID` to stop at its next stage boundary.
    public func cancel(jobID: UUID) async {
        await sessions[jobID]?.client.requestCancellation()
    }

    /// Ends every helper this runner started. Call it when the host quits.
    public func shutdown() async {
        for id in sessions.keys { await closeSession(for: id) }
    }

    private func stageResult(named workerStage: String, for job: TranscriptionJob) async throws -> WorkerStageResult {
        try await startSessionIfNeeded(for: job)
        while true {
            guard var session = sessions[job.id] else {
                throw WorkerFailure(code: WorkerFailure.crashedCode, message: "The transcription helper for this job is no longer running.", stage: workerStage)
            }
            if let result = session.results.removeValue(forKey: workerStage) {
                sessions[job.id] = session
                return result
            }
            guard !session.finished else {
                throw WorkerFailure(
                    code: WorkerFailure.protocolErrorCode,
                    message: "The transcription helper finished without reporting the \(workerStage) stage.",
                    stage: workerStage,
                    completedStages: Array(session.results.keys)
                )
            }
            let event = try await session.client.nextRunEvent()
            guard var updated = sessions[job.id] else { continue }
            switch event {
            case let .progress(progress):
                emit(job, stage: progress.stage, progress: progress.progress)
            case let .stageResult(result):
                updated.results[result.stage] = result
            case .finished:
                updated.finished = true
            }
            sessions[job.id] = updated
        }
    }

    private func startSessionIfNeeded(for job: TranscriptionJob) async throws {
        guard sessions[job.id] == nil else { return }
        try FileManager.default.createDirectory(at: job.runDirectoryURL, withIntermediateDirectories: true)
        let client = WorkerClient(configuration: .init(
            installation: configuration.installation,
            workingDirectoryURL: configuration.workingDirectoryURL,
            environment: configuration.environment,
            responseTimeout: configuration.responseTimeout
        ))
        let requestID = "\(job.runID.uuidString)"
        do {
            try await client.handshake()
            try await client.startRun(WorkerRunRequest(
                requestID: requestID,
                sourceURL: job.sourceSnapshotURL,
                runDirectoryURL: job.runDirectoryURL,
                knownSpeakerCount: job.request.speakerCount.knownCount,
                additionalOptions: additionalRunOptions
            ))
        } catch {
            await client.shutdown()
            throw error
        }
        sessions[job.id] = Session(client: client, requestID: requestID, runDirectoryURL: job.runDirectoryURL)
    }

    /// Consumes the helper's final `complete` record, then releases it. Holding
    /// the model-loading process open past the last stage would compete with a
    /// recording for memory.
    private func finish(_ job: TranscriptionJob) async throws {
        while let session = sessions[job.id], !session.finished {
            let event = try await session.client.nextRunEvent()
            guard var updated = sessions[job.id] else { return }
            switch event {
            case let .progress(progress): emit(job, stage: progress.stage, progress: progress.progress)
            case let .stageResult(result): updated.results[result.stage] = result
            case .finished: updated.finished = true
            }
            sessions[job.id] = updated
        }
        await closeSession(for: job.id)
    }

    private func closeSession(for jobID: UUID) async {
        guard let session = sessions.removeValue(forKey: jobID) else { return }
        await session.client.shutdown()
    }

    private func emit(
        _ job: TranscriptionJob,
        stage: String,
        progress: TranscriptionProgress? = nil,
        error: TranscriptionDiagnostic? = nil
    ) {
        eventHandler?(TranscriptionEvent(requestID: job.request.requestID, stage: stage, progress: progress, error: error))
    }
}

private extension TranscriptionSpeakerCount {
    var knownCount: Int? {
        guard case let .known(count) = self else { return nil }
        return count
    }
}
