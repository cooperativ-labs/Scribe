import AppKit
import AVFoundation
import Foundation
import Platform
import ScribeAppCore
import Storage

/// Main-actor adapter that connects the durable actor to the menu-bar contract.
/// The capture actor remains the sole owner of start/stop state; this type only
/// translates commands and published facts into renderable snapshots.
@MainActor
public final class LiveRecordingCoordinator: RecordingCoordinating {
    public typealias ProcessingSubmission = @Sendable (URL, ProcessingJobDescriptor) async -> Void
    public typealias CaptureActivityHandler = @Sendable (Bool) async -> Void
    /// Called once, after the launch-time recovery scan, with whatever it
    /// repaired. The app composes the menu's recovery notice from this and from
    /// the processing work the same launch requeued.
    public typealias RecoveryReporter = @MainActor ([SessionStore.RecoveredSession]) -> Void
    public private(set) var snapshot: RecorderSnapshot {
        didSet { if snapshot != oldValue { broadcaster.publish(snapshot) } }
    }

    public var terminationHandler: (@MainActor () -> Void)?
    /// Set immediately after construction, like `terminationHandler`: the owner
    /// cannot pass a closure capturing itself into its own initializer. The
    /// launch scan is asynchronous, so it is always assigned before the result
    /// arrives.
    public var recoveryReporter: RecoveryReporter?

    private let permissions: any RecordingPermissionProviding
    private let sourceProvider: any CaptureSourceProviding
    private let engine: RecordingCoordinator
    private let queue = RecordingCommandQueue()
    private let broadcaster = RecorderSnapshotBroadcaster()
    private let openFolder: @MainActor (URL) -> Void
    private let processingSubmission: ProcessingSubmission?
    private let captureActivityHandler: CaptureActivityHandler?
    private var eventTask: Task<Void, Never>?
    private var interruptionObservers: [NSObjectProtocol] = []
    private let permissionMonitor: PermissionService?
    private let outputDeviceMonitor: OutputDeviceMonitor

    public init(
        snapshot: RecorderSnapshot,
        permissions: any RecordingPermissionProviding,
        sourceProvider: any CaptureSourceProviding = SystemCaptureSourceProvider(),
        openFolder: @escaping @MainActor (URL) -> Void = { _ in },
        scheduler: (any ProcessingScheduler)? = nil,
        processingSubmission: ProcessingSubmission? = nil,
        captureActivityHandler: CaptureActivityHandler? = nil,
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.snapshot = snapshot
        self.permissions = permissions
        self.sourceProvider = sourceProvider
        self.openFolder = openFolder
        self.processingSubmission = processingSubmission
        self.captureActivityHandler = captureActivityHandler
        permissionMonitor = permissions as? PermissionService
        let initialConfiguration = Self.configuration(from: snapshot, appBuild: appBuild, macOSVersion: macOSVersion)
        let engine = RecordingCoordinator(
            configuration: initialConfiguration,
            permissions: permissions,
            captureFactory: { configuration, store, events in
                CaptureService(
                    configuration: CaptureConfiguration(
                        applicationBundleIdentifier: configuration.selectedApplicationBundleIdentifier,
                        microphoneUniqueID: configuration.selectedMicrophoneID
                    ),
                    sourceProvider: sourceProvider,
                    sink: { buffer in
                        // `SessionStore` signals a clean low-space stop through
                        // its configured requester. Other I/O failures leave
                        // recoverable originals rather than blocking callbacks.
                        try? store.append(buffer)
                    },
                    events: events
                )
            },
            scheduler: scheduler
        )
        self.engine = engine
        let outputDeviceMonitor = OutputDeviceMonitor { [weak engine] change in
            Task { await engine?.recordOutputRouteChange(change) }
        }
        self.outputDeviceMonitor = outputDeviceMonitor
        permissionMonitor?.observeRevocations { [weak engine] revocation in
            Task { await engine?.handleInterruption(.permissionRevoked(revocation)) }
        }
        eventTask = Task { [weak self, engine] in
            let events = await engine.events()
            for await event in events {
                self?.receive(event)
            }
        }
        // Recovery runs before any new stream can be created, and its result is
        // reported rather than discarded: a repaired meeting the person never
        // hears about is indistinguishable from a lost one.
        Task { [weak self, engine] in
            let recovered = (try? await engine.recoverIncompleteSessions()) ?? []
            guard !recovered.isEmpty else { return }
            self?.recoveryReporter?(recovered)
        }
        installInterruptionObservers()
        outputDeviceMonitor.start()
    }

    deinit {
        eventTask?.cancel()
        outputDeviceMonitor.stop()
    }

    public func submit(_ command: RecordingCommand) {
        queue.enqueue(command) { [weak self] in await self?.perform(command) }
    }

    public func reportShortcutRegistration(_ report: HotkeyRegistrationReport) {
        snapshot.shortcutIssues = HotkeyAction.allCases.compactMap { action in
            guard let failure = report.failures[action] else { return nil }
            return "\(action == .start ? "Start" : "Stop") shortcut: \(failure.errorDescription ?? "unavailable")"
        }
    }

    public func observeSnapshot(_ observer: @escaping @MainActor (RecorderSnapshot) -> Void) -> RecorderObservationToken {
        let token = broadcaster.addObserver(observer)
        observer(snapshot)
        return token
    }

    /// Applies a Settings folder selection before the next start. An active
    /// session retains its already-reserved directory.
    public func setRecordingsFolder(_ url: URL) { snapshot.recordingsFolderURL = url }

    // MARK: Background processing

    /// Adds or updates a background job row. Idempotent by ID so the coordinator's
    /// own `finalRecordingReady` and the processing queue's `queued` event, which
    /// describe the same work, cannot produce two rows for one meeting.
    public func noteBackgroundJob(id: UUID, title: String, fractionCompleted: Double? = nil) {
        let job = BackgroundProcessingJob(id: id, title: title, fractionCompleted: fractionCompleted)
        if let index = snapshot.processing.jobs.firstIndex(where: { $0.id == id }) {
            snapshot.processing.jobs[index] = job
        } else {
            snapshot.processing.jobs.append(job)
        }
    }

    /// Retires a background job row. Capture state is untouched: the recorder may
    /// already be recording the next meeting while this one finishes.
    public func finishBackgroundJob(id: UUID) {
        snapshot.processing.jobs.removeAll { $0.id == id }
    }

    /// Surfaces a background failure without disturbing capture. Reported for a
    /// failed cleanup and for a refused transcription handoff alike: in both
    /// cases the originals were kept and nothing was published in their place.
    public func reportBackgroundFailure(_ failure: RecorderFailure?) {
        snapshot.processing.lastFailure = failure
    }

    /// Shows, or clears, what launch recovery found.
    public func setRecoveryNotice(_ notice: String?) {
        snapshot.recoveryNotice = notice
    }

    // MARK: Termination

    /// Stops an active capture through the same serialized path as the menu and
    /// calls back only once originals are committed.
    ///
    /// Termination needs this because submitting a stop and exiting immediately
    /// would race the drain: the manifest would still say `capturing` and the
    /// session would come back as recovery work instead of a finished meeting.
    public func stopForTermination(then completion: @escaping @MainActor () -> Void) {
        queue.enqueue(.stop) { [weak self] in
            await self?.perform(.stop)
            completion()
        }
    }

    private func perform(_ command: RecordingCommand) async {
        switch command {
        case .start:
            await engine.updateConfiguration(Self.configuration(from: snapshot))
            await engine.start()
            if case .recording = await engine.state() { permissionMonitor?.startMonitoring() }
        case .stop: await engine.stop()
        case .pause: await engine.pause()
        case .resume: await engine.resume()
        case .selectApplication(let id): snapshot.selectedApplicationID = id
        case .selectMicrophone(let id): snapshot.selectedMicrophoneID = id
        case .refreshSources:
            snapshot.applications = (try? await sourceProvider.shareableApplications()) ?? snapshot.applications
            snapshot.microphones = await sourceProvider.availableMicrophones()
            snapshot.systemDefaultMicrophoneID = await sourceProvider.systemDefaultMicrophone()?.uniqueID
        case .openRecordingsFolder: openFolder(snapshot.recordingsFolderURL)
        case .requestPermissions: snapshot.permissions = await permissions.requestMissingPermissions()
        case .openSystemSettings(let pane): permissions.openSystemSettings(pane)
        case .quit:
            await engine.stop()
            terminationHandler?()
        }
    }

    private func receive(_ event: RecordingCoordinatorEvent) {
        switch event {
        case .stateChanged(let state):
            snapshot.state = Self.menuState(from: state)
            if case .idle = state { permissionMonitor?.stopMonitoring() }
            let captureIsActive: Bool
            switch state {
            case .starting, .recording, .paused, .stopping: captureIsActive = true
            case .idle, .error: captureIsActive = false
            }
            if let captureActivityHandler {
                Task { await captureActivityHandler(captureIsActive) }
            }
        case .recordingStopped:
            break // The next event makes processing visible without blocking capture.
        case .finalRecordingReady(let ready):
            noteBackgroundJob(id: ready.processingJob.id, title: "Processing recording")
            if let processingSubmission {
                Task { await processingSubmission(ready.sessionDirectory, ready.processingJob) }
            }
        }
    }

    private static func configuration(
        from snapshot: RecorderSnapshot,
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> RecordingCoordinatorConfiguration {
        RecordingCoordinatorConfiguration(
            recordingsDirectory: snapshot.recordingsFolderURL,
            appBuild: appBuild,
            macOSVersion: macOSVersion,
            selectedApplicationBundleIdentifier: snapshot.selectedApplicationID,
            selectedMicrophoneID: snapshot.selectedMicrophoneID
        )
    }

    private static func menuState(from state: RecordingCoordinatorState) -> RecorderState {
        switch state {
        case .idle: .idle
        case .starting: .starting
        case .recording(let activity): .recording(activity)
        case .paused(let activity): .paused(activity)
        case .stopping: .stopping
        case .error(let failure): .failed(failure)
        }
    }

    private func installInterruptionObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        interruptionObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.engine.handleInterruption(.sleep) }
        })
        interruptionObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard bundleIdentifier == self?.snapshot.selectedApplicationID else { return }
                await self?.engine.handleInterruption(.selectedApplicationExited)
            }
        })
        interruptionObservers.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let uniqueID = (notification.object as? AVCaptureDevice)?.uniqueID
            Task { @MainActor [weak self] in
                guard uniqueID == self?.snapshot.selectedMicrophoneID else { return }
                await self?.engine.handleInterruption(.microphoneDisconnected)
            }
        })
    }
}
