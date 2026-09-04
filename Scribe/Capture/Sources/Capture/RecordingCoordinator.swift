import Foundation
import Platform
import ScribeAppCore
import Storage

/// The small surface the coordinator needs from an active `SCStream`.
/// Keeping it separate from ScreenCaptureKit makes lifecycle and fault tests
/// deterministic and lets the actor remain responsible for all state changes.
public protocol RecordingCaptureControlling: Sendable {
    func start() async throws -> ResolvedCaptureSources
    func stop() async -> CaptureStatistics
}

extension CaptureService: RecordingCaptureControlling {}

public enum RecordingCoordinatorState: Equatable, Sendable {
    case idle
    case starting
    case recording(RecordingActivity)
    case stopping
    case error(RecorderFailure)
}

public enum RecordingStopReason: Equatable, Sendable {
    case user
    case microphoneDisconnected
    case selectedApplicationExited
    case streamFailure(RecorderFailure)
    case sleep
    case permissionRevoked(PermissionRevocation)
    case lowFreeSpace

    var journalReason: String {
        switch self {
        case .user: "user-requested"
        case .microphoneDisconnected: "microphone-disconnected"
        case .selectedApplicationExited: "selected-application-exited"
        case .streamFailure: "unrecoverable-stream-error"
        case .sleep: "system-sleep"
        case .permissionRevoked: "permission-revoked"
        case .lowFreeSpace: "low-free-space"
        }
    }

    var isInterruption: Bool {
        if case .user = self { return false }
        return true
    }
}

public enum RecordingCoordinatorEvent: Sendable, Equatable {
    /// Raw capture has stopped and original CAF files are closed. Processing may
    /// still be pending or running, so consumers must not imply final output.
    case recordingStopped(RecordingStoppedEvent)
    /// The finalized session is safe for downstream processing and import.
    case finalRecordingReady(FinalRecordingReadyEvent)
    case stateChanged(RecordingCoordinatorState)
}

public struct RecordingStoppedEvent: Sendable, Equatable {
    public let sessionID: UUID
    public let sessionDirectory: URL
    public let reason: RecordingStopReason
    public let statistics: CaptureStatistics

    public init(sessionID: UUID, sessionDirectory: URL, reason: RecordingStopReason, statistics: CaptureStatistics) {
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        self.reason = reason
        self.statistics = statistics
    }
}

public struct FinalRecordingReadyEvent: Sendable, Equatable {
    public let sessionID: UUID
    public let sessionDirectory: URL
    public let processingJob: ProcessingJobDescriptor
    public let deferral: ProcessingJobDeferral?

    public init(sessionID: UUID, sessionDirectory: URL, processingJob: ProcessingJobDescriptor, deferral: ProcessingJobDeferral?) {
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        self.processingJob = processingJob
        self.deferral = deferral
    }
}

public struct RecordingCoordinatorConfiguration: Sendable {
    public let recordingsDirectory: URL
    public let appBuild: String
    public let macOSVersion: String
    public let selectedApplicationBundleIdentifier: String?
    public let selectedMicrophoneID: String?
    public let minimumFreeBytes: Int64

    public init(
        recordingsDirectory: URL,
        appBuild: String,
        macOSVersion: String,
        selectedApplicationBundleIdentifier: String?,
        selectedMicrophoneID: String?,
        minimumFreeBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.recordingsDirectory = recordingsDirectory
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.selectedApplicationBundleIdentifier = selectedApplicationBundleIdentifier
        self.selectedMicrophoneID = selectedMicrophoneID
        self.minimumFreeBytes = minimumFreeBytes
    }
}

/// Serializes the recorder's whole capture lifecycle.
///
/// The actor is deliberately below the menu layer: it owns the durable state
/// machine while any UI adapter can translate its events into snapshots. This
/// makes interruptions from ScreenCaptureKit, device observation, power
/// notifications, and a Stop button use exactly the same finalization path.
public actor RecordingCoordinator {
    public typealias CaptureFactory = @Sendable (RecordingCoordinatorConfiguration, SessionStore, @escaping @Sendable (CaptureEvent) -> Void) -> any RecordingCaptureControlling
    public typealias StoreFactory = @Sendable (SessionStoreConfiguration) throws -> SessionStore

    private var configuration: RecordingCoordinatorConfiguration
    private let permissions: any RecordingPermissionProviding
    private let captureFactory: CaptureFactory
    private let storeFactory: StoreFactory
    private let scheduler: (any ProcessingScheduler)?
    private let now: @Sendable () -> Date
    private let freeSpace: @Sendable (URL) throws -> Int64

    private var currentState: RecordingCoordinatorState = .idle
    private var activeStore: SessionStore?
    private var activeCapture: (any RecordingCaptureControlling)?
    /// A delegate failure can arrive while `startCapture()` is resuming. Do not
    /// lose that interruption merely because the actor has not published
    /// `.recording` yet.
    private var pendingInterruption: RecordingStopReason?
    private var eventContinuations: [UUID: AsyncStream<RecordingCoordinatorEvent>.Continuation] = [:]

    public init(
        configuration: RecordingCoordinatorConfiguration,
        permissions: any RecordingPermissionProviding,
        captureFactory: @escaping CaptureFactory,
        storeFactory: @escaping StoreFactory = { try SessionStore.create(configuration: $0) },
        scheduler: (any ProcessingScheduler)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        freeSpace: @escaping @Sendable (URL) throws -> Int64 = SessionStore.availableCapacity
    ) {
        self.configuration = configuration
        self.permissions = permissions
        self.captureFactory = captureFactory
        self.storeFactory = storeFactory
        self.scheduler = scheduler
        self.now = now
        self.freeSpace = freeSpace
    }

    public func state() -> RecordingCoordinatorState { currentState }

    /// Applies source and destination settings only while idle. A live stream
    /// keeps its original sources and directory until it is finalized.
    public func updateConfiguration(_ configuration: RecordingCoordinatorConfiguration) {
        guard currentState == .idle || isErrorState else { return }
        self.configuration = configuration
    }

    public func events() -> AsyncStream<RecordingCoordinatorEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.yield(.stateChanged(currentState))
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    /// Performs permission, destination, reserve-space, source-selection, and
    /// stream-start preflight in one serialized transition.
    public func start() async {
        guard currentState == .idle || isErrorState else { return }
        transition(to: .starting)
        do {
            let permissionSnapshot = permissions.currentStatus()
            if let failure = permissionSnapshot.blockingFailure { throw CoordinatorError.failure(failure) }
            try preflightDestination()

            let sessionID = UUID()
            let scope = CaptureScope(applicationBundleIdentifiers: configuration.selectedApplicationBundleIdentifier.map { [$0] } ?? [], processIdentifiers: [])
            let microphone = AudioDeviceIdentity(uniqueID: configuration.selectedMicrophoneID ?? "unresolved", name: "Unresolved microphone")
            let store = try storeFactory(SessionStoreConfiguration(
                recordingsDirectory: configuration.recordingsDirectory,
                sessionID: sessionID,
                appBuild: configuration.appBuild,
                macOSVersion: configuration.macOSVersion,
                captureScope: scope,
                microphone: microphone,
                minimumFreeBytes: configuration.minimumFreeBytes,
                freeSpaceProvider: freeSpace,
                cleanStopRequester: { [weak self] in
                    Task { await self?.stop(reason: .lowFreeSpace) }
                }
            ))
            activeStore = store
            let capture = captureFactory(configuration, store) { [weak self] event in
                Task { await self?.handleCaptureEvent(event) }
            }
            activeCapture = capture
            let sources = try await capture.start()
            try store.updateCaptureSources(CaptureSourceUpdate(scope: sources.scope, microphone: sources.microphone))
            transition(to: .recording(RecordingActivity(sessionID: sessionID, startedAt: now())))
            if let pendingInterruption {
                self.pendingInterruption = nil
                await stop(reason: pendingInterruption)
            }
        } catch {
            let failure = Self.failure(from: error)
            // A failed stream start can leave a reserved session but no audio.
            // Close it as interrupted so launch recovery never mistakes it for a
            // live capture.
            if let store = activeStore {
                try? store.recordInterruption(reason: "start-failed: \(failure.code)", at: now())
                try? store.finish()
                _ = try? store.commitCapture(state: .interrupted, completionStatus: .failed, endedAt: now(), interruptionReason: failure.code)
            }
            activeCapture = nil
            activeStore = nil
            transition(to: .error(failure))
        }
    }

    public func stop() async { await stop(reason: .user) }

    public func stop(reason: RecordingStopReason) async {
        guard case .recording(let activity) = currentState else { return }
        transition(to: .stopping)
        let store = activeStore
        let statistics = await activeCapture?.stop() ?? CaptureStatistics(
            system: .init(enqueuedBuffers: 0, droppedBuffers: 0, droppedFrames: 0, queuedBytes: 0, peakQueuedBytes: 0),
            microphone: .init(enqueuedBuffers: 0, droppedBuffers: 0, droppedFrames: 0, queuedBytes: 0, peakQueuedBytes: 0),
            rejectedBuffers: 0,
            discardedScreenFrames: 0
        )
        activeCapture = nil

        guard let store else {
            transition(to: .error(RecorderFailure(code: "recording.storeMissing", message: "The active recording store was lost.", recoveryHint: "Start a new recording.")))
            return
        }
        do {
            if reason.isInterruption { try store.recordInterruption(reason: reason.journalReason, at: now()) }
            try store.finish()
            let captureState: CaptureState = reason.isInterruption ? .interrupted : .complete
            let completion: RecorderSessionCompletionStatus = reason.isInterruption ? .interrupted : .complete
            _ = try store.commitCapture(state: captureState, completionStatus: completion, endedAt: now(), interruptionReason: reason.isInterruption ? reason.journalReason : nil)
            emit(.recordingStopped(RecordingStoppedEvent(sessionID: activity.sessionID, sessionDirectory: store.sessionDirectory, reason: reason, statistics: statistics)))
            let job = ProcessingJobDescriptor(id: activity.sessionID, kind: "recording-post-process")
            let deferral = await scheduler?.requestDeferral(for: job)
            emit(.finalRecordingReady(FinalRecordingReadyEvent(sessionID: activity.sessionID, sessionDirectory: store.sessionDirectory, processingJob: job, deferral: deferral)))
            activeStore = nil
            transition(to: .idle)
        } catch {
            activeStore = nil
            transition(to: .error(Self.failure(from: error)))
        }
    }

    /// Microphone removal, application exit, sleep, stream failure, and TCC
    /// revocation all intentionally share the clean stop path.
    public func handleInterruption(_ reason: RecordingStopReason) async {
        guard reason.isInterruption else { return }
        if currentState == .starting {
            pendingInterruption = reason
            return
        }
        await stop(reason: reason)
    }

    public func recordOutputRouteChange(_ change: OutputDeviceChange) async {
        guard case .recording = currentState, let activeStore else { return }
        do { try activeStore.recordOutputDeviceChange(change) }
        catch { transition(to: .error(Self.failure(from: error))) }
    }

    /// Run once at app launch, before any new stream is created. Existing raw
    /// data is repaired in place and marked interrupted; it is never replaced.
    @discardableResult
    public func recoverIncompleteSessions() throws -> [SessionStore.RecoveredSession] {
        try SessionStore.recoverIncompleteSessions(in: configuration.recordingsDirectory)
    }

    private var isErrorState: Bool { if case .error = currentState { return true }; return false }

    private func preflightDestination() throws {
        try FileManager.default.createDirectory(at: configuration.recordingsDirectory, withIntermediateDirectories: true)
        let available = try freeSpace(configuration.recordingsDirectory)
        guard available >= configuration.minimumFreeBytes else {
            throw CoordinatorError.failure(RecorderFailure(code: "recording.insufficientFreeSpace", message: "Only \(available) bytes are available for recordings.", recoveryHint: "Free disk space or choose a different recordings folder."))
        }
        let probe = configuration.recordingsDirectory.appendingPathComponent(".scribe-write-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw CoordinatorError.failure(RecorderFailure(code: "recording.destinationNotWritable", message: "Scribe cannot write to the recordings folder.", recoveryHint: "Choose a writable recordings folder in Settings."))
        }
        try FileManager.default.removeItem(at: probe)
    }

    private func handleCaptureEvent(_ event: CaptureEvent) async {
        switch event {
        case .streamFailed(let failure): await handleInterruption(.streamFailure(failure))
        default: break
        }
    }

    private func transition(to state: RecordingCoordinatorState) {
        currentState = state
        emit(.stateChanged(state))
    }

    private func emit(_ event: RecordingCoordinatorEvent) {
        for continuation in eventContinuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { eventContinuations[id] = nil }

    private static func failure(from error: Error) -> RecorderFailure {
        if let coordinatorError = error as? CoordinatorError { return coordinatorError.failure }
        if let captureError = error as? CaptureServiceError { return captureError.failure }
        return RecorderFailure(code: "recording.unexpected", message: error.localizedDescription, recoveryHint: "Try starting a new recording. If this repeats, choose another recordings folder.")
    }

    private enum CoordinatorError: Error {
        case failure(RecorderFailure)
        var failure: RecorderFailure { switch self { case .failure(let failure): failure } }
    }
}
