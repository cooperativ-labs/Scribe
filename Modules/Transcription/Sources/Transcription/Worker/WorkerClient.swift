import Foundation
import ScribeAppCore

/// A structured failure from the helper or from the channel to it.
///
/// Every non-success outcome — a crash, a timeout, an oversize record, a
/// refused model set, a cancellation — arrives as one of these rather than as
/// an opaque process error, so a caller can decide between retrying and
/// surfacing the problem. `completedStages` and `checkpointsPreserved` say what
/// a retry may keep.
public struct WorkerFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String
    /// The stage that was running, when the worker or the client knows it.
    public let stage: String?
    /// Stages whose durable result files were committed before the failure.
    public let completedStages: [String]
    public let checkpointsPreserved: Bool
    public let details: [String: WorkerJSONValue]

    public init(
        code: String,
        message: String,
        stage: String? = nil,
        completedStages: [String] = [],
        checkpointsPreserved: Bool = false,
        details: [String: WorkerJSONValue] = [:]
    ) {
        self.code = code
        self.message = message
        self.stage = stage
        self.completedStages = completedStages
        self.checkpointsPreserved = checkpointsPreserved
        self.details = details
    }

    public var isCancellation: Bool { code == WorkerFailure.cancelledCode }

    public static let cancelledCode = "cancelled"
    public static let crashedCode = "worker_crashed"
    public static let timedOutCode = "worker_timed_out"
    public static let protocolErrorCode = "protocol_error"
    public static let launchFailedCode = "worker_launch_failed"

    /// The shared diagnostic shape the coordinator persists on a failed job.
    public var diagnostic: TranscriptionDiagnostic {
        TranscriptionDiagnostic(code: "transcription.worker.\(code)", message: message)
    }
}

extension WorkerFailure: LocalizedError {
    public var errorDescription: String? { message }
}

public struct WorkerHandshake: Sendable, Equatable {
    public let protocolVersion: Int
    public let workerVersion: String
    public let networkingDisabled: Bool
    public let runtimeDownloadsDisabled: Bool
    public let telemetryDisabled: Bool
}

public struct WorkerStageProgress: Sendable, Equatable {
    public let stage: String
    public let state: String
    public let progress: TranscriptionProgress?
}

public struct WorkerStageResult: Sendable, Equatable {
    public let stage: String
    public let status: String
    /// The result file's name relative to the run directory. Large data never
    /// travels over the channel.
    public let resultFileName: String?
    public let sha256: String?
}

public enum WorkerRunEvent: Sendable, Equatable {
    case progress(WorkerStageProgress)
    case stageResult(WorkerStageResult)
    /// The worker reported the whole pipeline finished.
    case finished
}

public struct WorkerRunRequest: Sendable, Equatable {
    public var requestID: String
    public var sourceURL: URL
    public var runDirectoryURL: URL
    public var knownSpeakerCount: Int?
    /// Extra payload values. The production helper refuses its test-only keys
    /// unless its own test environment variable is set, so this cannot weaken a
    /// shipped build.
    public var additionalOptions: [String: WorkerJSONValue]

    public init(
        requestID: String = UUID().uuidString,
        sourceURL: URL,
        runDirectoryURL: URL,
        knownSpeakerCount: Int? = nil,
        additionalOptions: [String: WorkerJSONValue] = [:]
    ) {
        self.requestID = requestID
        self.sourceURL = sourceURL
        self.runDirectoryURL = runDirectoryURL
        self.knownSpeakerCount = knownSpeakerCount
        self.additionalOptions = additionalOptions
    }
}

public struct WorkerEmbeddingRange: Sendable, Equatable {
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval

    public init(startSeconds: TimeInterval, endSeconds: TimeInterval) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

public struct WorkerExtractedEmbedding: Sendable, Equatable {
    public let vector: [Float]
    public let modelID: String
    public let modelRevision: String
    public let preprocessingVersion: String
    public let normalizationVersion: String
    public let usableSpeechDuration: TimeInterval
}

/// Launches the bundled helper and exchanges versioned JSON records with it.
///
/// The client owns exactly one child process and one in-flight request. It does
/// not know about jobs, checkpoints, or the queue: it reports what the helper
/// said and what happened to the process, and `WorkerStageRunner` turns that
/// into coordinator state.
public actor WorkerClient {
    public struct Configuration: Sendable {
        public var installation: WorkerInstallation
        public var workingDirectoryURL: URL?
        public var environment: [String: String]
        /// The longest silence tolerated between records. A model stage is slow
        /// but never silent for this long, so exceeding it means the helper is
        /// wedged rather than working.
        public var responseTimeout: Duration
        /// How long a terminating helper is given before `SIGKILL`.
        public var terminationGracePeriod: Duration

        public init(
            installation: WorkerInstallation,
            workingDirectoryURL: URL? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            responseTimeout: Duration = .seconds(600),
            terminationGracePeriod: Duration = .seconds(2)
        ) {
            self.installation = installation
            self.workingDirectoryURL = workingDirectoryURL
            self.environment = environment
            self.responseTimeout = responseTimeout
            self.terminationGracePeriod = terminationGracePeriod
        }
    }

    private enum Awaited: Sendable {
        case item(WorkerInboxItem)
        case timedOut
        case sleepCancelled
    }

    private let configuration: Configuration
    private var transport: WorkerProcessTransport?
    private var activeRequestID: String?
    private var completedStages: [String] = []
    private var lastStartedStage: String?
    private var cancellationSent = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var isRunning: Bool { transport?.isRunning ?? false }

    /// The helper's process identifier while it is running.
    public var processIdentifier: Int32? { transport?.processIdentifier }

    /// Launches the helper. A launch failure is structured like any other
    /// worker failure so a caller has one thing to handle.
    public func start() throws {
        guard transport == nil else { return }
        let transport = WorkerProcessTransport(
            executableURL: configuration.installation.executableURL,
            arguments: configuration.installation.arguments,
            environment: configuration.environment,
            currentDirectoryURL: configuration.workingDirectoryURL
        )
        do { try transport.start() } catch {
            throw WorkerFailure(
                code: WorkerFailure.launchFailedCode,
                message: "The transcription helper at \(configuration.installation.executableURL.path) could not be launched: \(error.localizedDescription)"
            )
        }
        self.transport = transport
    }

    /// Confirms the helper speaks this protocol version before any job is sent.
    @discardableResult
    public func handshake(requestID: String = UUID().uuidString) async throws -> WorkerHandshake {
        try start()
        try send(WorkerEnvelope(kind: .request, requestID: requestID, payload: .object(["operation": .string("handshake")])))
        while true {
            let envelope = try await receive(stage: "handshake")
            guard envelope.requestID == requestID else { continue }
            switch envelope.kind {
            case .stageResult:
                let payload = envelope.payload.objectValue ?? [:]
                let version = payload["protocolVersion"]?.integerValue ?? WorkerEnvelope.currentVersion
                guard version == WorkerEnvelope.currentVersion else {
                    throw WorkerFailure(
                        code: WorkerFailure.protocolErrorCode,
                        message: "The transcription helper speaks protocol version \(version); this build supports version \(WorkerEnvelope.currentVersion).",
                        stage: "handshake"
                    )
                }
                return WorkerHandshake(
                    protocolVersion: version,
                    workerVersion: payload["workerVersion"]?.stringValue ?? "unknown",
                    networkingDisabled: payload["networking"]?.stringValue == "disabled",
                    runtimeDownloadsDisabled: payload["runtimeDownloads"]?.boolValue == false,
                    telemetryDisabled: payload["telemetry"]?.boolValue == false
                )
            case .error:
                throw failure(from: envelope, stage: "handshake")
            case .progress, .request, .cancel:
                continue
            }
        }
    }

    /// Sends one `run` request. Its events are pulled with `nextRunEvent()`.
    public func startRun(_ request: WorkerRunRequest) throws {
        try start()
        var payload: [String: WorkerJSONValue] = [
            "operation": .string("run"),
            "sourcePath": .string(request.sourceURL.path),
            "runDirectory": .string(request.runDirectoryURL.path),
        ]
        if let knownSpeakerCount = request.knownSpeakerCount { payload["knownSpeakerCount"] = .number(Double(knownSpeakerCount)) }
        payload.merge(request.additionalOptions) { _, new in new }
        activeRequestID = request.requestID
        completedStages = []
        lastStartedStage = nil
        cancellationSent = false
        try send(WorkerEnvelope(kind: .request, requestID: request.requestID, payload: .object(payload)))
    }

    /// Extracts one enrollment embedding without running ASR. The caller must
    /// handshake first, matching the lifecycle used by normal worker runs.
    public func extractEmbedding(
        sourceURL: URL,
        ranges: [WorkerEmbeddingRange],
        clipOutputURL: URL? = nil,
        requestID: String = UUID().uuidString
    ) async throws -> WorkerExtractedEmbedding {
        try start()
        let encodedRanges: [WorkerJSONValue] = ranges.map { range in
            .object([
                "startSeconds": .number(range.startSeconds),
                "endSeconds": .number(range.endSeconds),
            ])
        }
        var payload: [String: WorkerJSONValue] = [
            "operation": .string("extract_embedding"),
            "sourcePath": .string(sourceURL.path),
            "ranges": .array(encodedRanges),
        ]
        if let clipOutputURL { payload["clipOutputPath"] = .string(clipOutputURL.path) }
        try send(WorkerEnvelope(kind: .request, requestID: requestID, payload: .object(payload)))
        while true {
            let envelope = try await receive(stage: "extract_embedding")
            guard envelope.requestID == requestID else { continue }
            switch envelope.kind {
            case .stageResult:
                let payload = envelope.payload.objectValue ?? [:]
                guard payload["stage"]?.stringValue == "extract_embedding",
                      let values = payload["vector"]?.arrayValue,
                      !values.isEmpty,
                      let modelID = payload["modelID"]?.stringValue,
                      let modelRevision = payload["modelRevision"]?.stringValue,
                      let preprocessingVersion = payload["preprocessingVersion"]?.stringValue,
                      let normalizationVersion = payload["normalizationVersion"]?.stringValue,
                      let usableSpeechDuration = payload["usableSpeechDuration"]?.numberValue else {
                    throw WorkerFailure(
                        code: WorkerFailure.protocolErrorCode,
                        message: "The transcription helper returned an invalid speaker embedding.",
                        stage: "extract_embedding"
                    )
                }
                let vector = values.compactMap { $0.numberValue.map(Float.init) }
                guard vector.count == values.count, vector.allSatisfy(\.isFinite) else {
                    throw WorkerFailure(
                        code: WorkerFailure.protocolErrorCode,
                        message: "The transcription helper returned a malformed speaker vector.",
                        stage: "extract_embedding"
                    )
                }
                return WorkerExtractedEmbedding(
                    vector: vector,
                    modelID: modelID,
                    modelRevision: modelRevision,
                    preprocessingVersion: preprocessingVersion,
                    normalizationVersion: normalizationVersion,
                    usableSpeechDuration: usableSpeechDuration
                )
            case .error:
                throw failure(from: envelope, stage: "extract_embedding")
            case .progress, .request, .cancel:
                continue
            }
        }
    }

    /// The next event of the in-flight run. Throws a `WorkerFailure` for a
    /// worker-reported error, a crash, a timeout, or a protocol fault.
    public func nextRunEvent() async throws -> WorkerRunEvent {
        guard let activeRequestID else {
            throw WorkerFailure(code: WorkerFailure.protocolErrorCode, message: "No transcription run is in flight.")
        }
        while true {
            let envelope = try await receive(stage: lastStartedStage)
            guard envelope.requestID == activeRequestID else { continue }
            switch envelope.kind {
            case .progress:
                let payload = envelope.payload.objectValue ?? [:]
                let stage = payload["stage"]?.stringValue ?? "unknown"
                lastStartedStage = stage
                return .progress(WorkerStageProgress(
                    stage: stage,
                    state: payload["state"]?.stringValue ?? "started",
                    progress: progress(from: payload)
                ))
            case .stageResult:
                let payload = envelope.payload.objectValue ?? [:]
                let stage = payload["stage"]?.stringValue ?? "unknown"
                // The acknowledgement of a `cancel` record is control traffic,
                // not a pipeline stage; the cancelled outcome arrives later as
                // a structured error at the next stage boundary.
                if stage == "cancel" { continue }
                if stage == "complete" {
                    self.activeRequestID = nil
                    return .finished
                }
                completedStages.append(stage)
                return .stageResult(WorkerStageResult(
                    stage: stage,
                    status: payload["status"]?.stringValue ?? "complete",
                    resultFileName: payload["resultPath"]?.stringValue,
                    sha256: payload["sha256"]?.stringValue
                ))
            case .error:
                self.activeRequestID = nil
                throw failure(from: envelope, stage: lastStartedStage)
            case .request, .cancel:
                continue
            }
        }
    }

    /// Asks the helper to stop. It observes this at its next stage boundary and
    /// leaves every committed stage file in place.
    public func requestCancellation() {
        guard let activeRequestID, !cancellationSent else { return }
        cancellationSent = true
        try? send(WorkerEnvelope(kind: .cancel, requestID: activeRequestID, payload: .object([:])))
    }

    /// Ends the helper, escalating to `SIGKILL` if it does not leave.
    public func shutdown() async {
        guard let transport else { return }
        self.transport = nil
        activeRequestID = nil
        transport.closeInput()
        transport.terminate()
        if await exitStatus(of: transport, within: configuration.terminationGracePeriod) == nil {
            transport.kill()
            _ = await exitStatus(of: transport)
        }
    }

    /// Polls for the recorded exit rather than blocking a cooperative thread in
    /// `waitUntilExit`, which runs a run loop and can never return here.
    private func exitStatus(of transport: WorkerProcessTransport, within limit: Duration = .seconds(2)) async -> WorkerProcessExit? {
        let step = Duration.milliseconds(20)
        var waited = Duration.zero
        while waited < limit {
            if let exit = transport.exitStatus { return exit }
            try? await Task.sleep(for: step)
            waited += step
        }
        return transport.exitStatus
    }

    private func send(_ envelope: WorkerEnvelope) throws {
        guard let transport else {
            throw WorkerFailure(code: WorkerFailure.launchFailedCode, message: "The transcription helper is not running.")
        }
        do { try transport.send(envelope) }
        catch let error as WorkerWireFormatError {
            throw WorkerFailure(
                code: WorkerFailure.protocolErrorCode,
                message: error.localizedDescription,
                stage: lastStartedStage,
                completedStages: completedStages,
                checkpointsPreserved: !completedStages.isEmpty
            )
        } catch {
            throw crashFailure(stage: lastStartedStage, reason: "The helper's input pipe is closed: \(error.localizedDescription)")
        }
    }

    private func receive(stage: String?) async throws -> WorkerEnvelope {
        guard let transport else {
            throw WorkerFailure(code: WorkerFailure.launchFailedCode, message: "The transcription helper is not running.")
        }
        switch await awaitNext(from: transport.inbox) {
        case let .item(.envelope(envelope)):
            return envelope
        case let .item(.wireFault(fault)):
            await shutdown()
            throw WorkerFailure(
                code: WorkerFailure.protocolErrorCode,
                message: fault.localizedDescription,
                stage: stage,
                completedStages: completedStages,
                checkpointsPreserved: !completedStages.isEmpty
            )
        case .item(.closed):
            // Standard output reached end of file, so the helper has written
            // everything it ever will. `terminate` only bounds the wait for a
            // helper that closed its output without leaving.
            let diagnostics = transport.diagnosticOutput
            transport.terminate()
            let exit = await exitStatus(of: transport)
            self.transport = nil
            activeRequestID = nil
            let cause = exit?.summary ?? "stopped writing"
            throw crashFailure(stage: stage, reason: "The transcription helper \(cause) before the stage finished.", diagnostics: diagnostics)
        case .item(.cancelled), .sleepCancelled:
            // The awaiting task was cancelled, so ask the helper to stop at its
            // next boundary rather than killing it mid-write.
            requestCancellation()
            throw WorkerFailure(
                code: WorkerFailure.cancelledCode,
                message: "Transcription was cancelled while stage \(stage ?? "unknown") was running.",
                stage: stage,
                completedStages: completedStages,
                checkpointsPreserved: true
            )
        case .timedOut:
            await shutdown()
            throw WorkerFailure(
                code: WorkerFailure.timedOutCode,
                message: "The transcription helper sent nothing for \(configuration.responseTimeout) during stage \(stage ?? "unknown").",
                stage: stage,
                completedStages: completedStages,
                checkpointsPreserved: !completedStages.isEmpty
            )
        }
    }

    private func awaitNext(from inbox: WorkerMessageInbox) async -> Awaited {
        let timeout = configuration.responseTimeout
        return await withTaskGroup(of: Awaited.self) { group in
            group.addTask { .item(await inbox.next()) }
            group.addTask {
                do { try await Task.sleep(for: timeout); return .timedOut }
                catch { return .sleepCancelled }
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            // Both children observe cancellation, so draining cannot block.
            for await _ in group {}
            return first
        }
    }

    private func crashFailure(stage: String?, reason: String, diagnostics: String? = nil) -> WorkerFailure {
        let diagnostics = diagnostics ?? transport?.diagnosticOutput ?? ""
        let message = diagnostics.isEmpty ? reason : "\(reason) Its last diagnostic output was: \(diagnostics)"
        return WorkerFailure(
            code: WorkerFailure.crashedCode,
            message: message,
            stage: stage,
            completedStages: completedStages,
            // Each stage result is committed atomically before the next stage
            // starts, so a later crash never invalidates an earlier one.
            checkpointsPreserved: !completedStages.isEmpty,
            details: diagnostics.isEmpty ? [:] : ["standardError": .string(diagnostics)]
        )
    }

    private func failure(from envelope: WorkerEnvelope, stage: String?) -> WorkerFailure {
        let payload = envelope.payload.objectValue ?? [:]
        let details = payload["details"]?.objectValue ?? [:]
        let reportedStage = details["stage"]?.stringValue ?? stage
        let code = payload["code"]?.stringValue ?? "worker_error"
        return WorkerFailure(
            code: code,
            message: payload["message"]?.stringValue ?? "The transcription helper reported an unspecified error.",
            stage: reportedStage,
            completedStages: completedStages,
            checkpointsPreserved: details["checkpointsPreserved"]?.boolValue ?? !completedStages.isEmpty,
            details: details
        )
    }

    private func progress(from payload: [String: WorkerJSONValue]) -> TranscriptionProgress? {
        guard let completed = payload["completedUnits"]?.integerValue,
              let total = payload["totalUnits"]?.integerValue, total > 0 else { return nil }
        return TranscriptionProgress(completedUnits: completed, totalUnits: total)
    }
}
