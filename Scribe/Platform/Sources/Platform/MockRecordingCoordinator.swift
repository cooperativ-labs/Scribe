import Foundation

/// A coordinator that fully implements the menu's contract without any capture.
///
/// It exists so the menu-bar interface can be built, tested, and run before the
/// capture core lands. Every state the menu renders is reachable from here, and
/// the command path is the real serialized one rather than a shortcut for tests.
///
/// Source enumeration is optional: pass a `CaptureSourceProviding` to populate
/// the pickers from the live system while recording itself stays simulated.
@MainActor
public final class MockRecordingCoordinator: RecordingCoordinating {
    public private(set) var snapshot: RecorderSnapshot {
        didSet {
            guard snapshot != oldValue else { return }
            broadcaster.publish(snapshot)
        }
    }

    // MARK: Scripting

    /// When true, `start` and `stop` park in `.starting` / `.stopping` until
    /// `finishStart()` / `finishStop()` is called, so those states can be shown.
    public var holdsTransitions = false
    /// Failure returned by the next start instead of entering `.recording`.
    public var startFailure: RecorderFailure?
    /// Failure returned by the next stop instead of returning to `.idle`.
    public var stopFailure: RecorderFailure?
    /// Status applied when a permission request runs without a live service.
    public var permissionRequestResult: PermissionSnapshot = .allGranted
    /// Applications and microphones offered when no live provider is attached.
    public var scriptedApplications: [CaptureApplicationOption] = []
    public var scriptedMicrophones: [CaptureMicrophoneOption] = []
    public var scriptedSystemDefaultMicrophoneID: String?
    /// Called when the user chooses Quit, after capture has been stopped.
    public var terminationHandler: (@MainActor () -> Void)?

    // MARK: Observed effects

    public private(set) var openedRecordingsFolderURLs: [URL] = []
    public private(set) var openedSettingsPanes: [SystemSettingsPane] = []
    public private(set) var permissionRequestCount = 0
    public private(set) var sourceRefreshCount = 0
    public private(set) var quitCount = 0
    /// Commands that reached the coordinator, including the harmless ones.
    public var acceptedCommands: [RecordingCommand] { queue.acceptedCommands }
    /// Commands that actually changed capture state.
    public private(set) var performedCommands: [RecordingCommand] = []

    private let queue = RecordingCommandQueue()
    private let broadcaster = RecorderSnapshotBroadcaster()
    private let sourceProvider: (any CaptureSourceProviding)?
    private let permissions: (any RecordingPermissionProviding)?
    private let now: @MainActor () -> Date
    private let openFolder: @MainActor (URL) -> Void
    private var pendingTransition: (@MainActor () -> Void)?

    public init(
        snapshot: RecorderSnapshot = RecorderSnapshot(),
        sourceProvider: (any CaptureSourceProviding)? = nil,
        permissions: (any RecordingPermissionProviding)? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        openFolder: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.sourceProvider = sourceProvider
        self.permissions = permissions
        self.now = now
        self.openFolder = openFolder
    }

    // MARK: RecordingCoordinating

    public func submit(_ command: RecordingCommand) {
        queue.enqueue(command) { [weak self] in
            await self?.perform(command)
        }
    }

    public func reportShortcutRegistration(_ report: HotkeyRegistrationReport) {
        snapshot.shortcutIssues = HotkeyAction.allCases.compactMap { action in
            guard let failure = report.failures[action] else { return nil }
            let label = action == .start ? "Start" : "Stop"
            return "\(label) shortcut: \(failure.errorDescription ?? "unavailable")"
        }
    }

    public func observeSnapshot(_ observer: @escaping @MainActor (RecorderSnapshot) -> Void) -> RecorderObservationToken {
        let token = broadcaster.addObserver(observer)
        observer(snapshot)
        return token
    }

    // MARK: Test and preview control

    /// Awaits every submitted command. Commands stay queued in submission order.
    public func waitUntilIdle() async {
        await queue.waitUntilIdle()
    }

    /// Completes a start or stop that was held in its transitional state.
    public func finishPendingTransition() {
        let transition = pendingTransition
        pendingTransition = nil
        transition?()
    }

    /// Drives the recorder into a failed state, as a capture error would.
    public func simulateFailure(_ failure: RecorderFailure) {
        snapshot.state = .failed(failure)
    }

    /// Marks a background processing job finished, as the queue would.
    public func completeBackgroundProcessing(_ id: UUID) {
        snapshot.processing.jobs.removeAll { $0.id == id }
    }

    public func setPermissions(_ permissions: PermissionSnapshot) {
        snapshot.permissions = permissions
    }

    /// Applies a folder chosen in Settings so Open Recordings Folder follows it.
    public func setRecordingsFolder(_ url: URL) {
        snapshot.recordingsFolderURL = url
    }

    // MARK: Command execution

    private func perform(_ command: RecordingCommand) async {
        switch command {
        case .start: startRecording()
        case .stop: stopRecording()
        case .pause: pauseRecording()
        case .resume: resumeRecording()
        case .selectApplication(let id):
            snapshot.selectedApplicationID = id
            performedCommands.append(command)
        case .selectMicrophone(let id):
            snapshot.selectedMicrophoneID = id
            performedCommands.append(command)
        case .refreshSources: await refreshSources()
        case .openRecordingsFolder:
            openedRecordingsFolderURLs.append(snapshot.recordingsFolderURL)
            openFolder(snapshot.recordingsFolderURL)
            performedCommands.append(command)
        case .requestPermissions: await requestPermissions()
        case .openSystemSettings(let pane):
            openedSettingsPanes.append(pane)
            permissions?.openSystemSettings(pane)
            performedCommands.append(command)
        case .quit: quit()
        }
    }

    /// Start is only meaningful from idle or failed; anything else is ignored so
    /// a double press or a shortcut during a transition cannot start a second
    /// capture.
    private func startRecording() {
        switch snapshot.state {
        case .idle, .failed: break
        case .starting, .recording, .paused, .stopping: return
        }
        performedCommands.append(.start)

        if let startFailure {
            self.startFailure = nil
            snapshot.state = .failed(startFailure)
            return
        }

        snapshot.state = .starting
        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, case .starting = snapshot.state else { return }
            snapshot.state = .recording(RecordingActivity(sessionID: UUID(), startedAt: now()))
        }
        if holdsTransitions {
            pendingTransition = complete
        } else {
            complete()
        }
    }

    /// Stop is only meaningful while a session exists, running or paused. Raw
    /// capture closing hands the session to background processing and returns
    /// the recorder to idle, so a new recording can start immediately.
    private func stopRecording() {
        guard let activity = snapshot.state.activity else { return }
        performedCommands.append(.stop)
        snapshot.state = .stopping

        let complete: @MainActor () -> Void = { [weak self] in
            guard let self, case .stopping = snapshot.state else { return }
            if let stopFailure {
                self.stopFailure = nil
                snapshot.state = .failed(stopFailure)
                return
            }
            snapshot.state = .idle
            snapshot.processing.jobs.append(
                BackgroundProcessingJob(id: activity.sessionID, title: "Processing recording", fractionCompleted: nil)
            )
        }
        if holdsTransitions {
            pendingTransition = complete
        } else {
            complete()
        }
    }

    /// Pause and resume are only meaningful against a live session, and neither
    /// is a transition: the session stays open, so no `holdsTransitions` step
    /// applies to either one.
    private func pauseRecording() {
        guard case .recording(let activity) = snapshot.state else { return }
        performedCommands.append(.pause)
        snapshot.state = .paused(activity)
    }

    private func resumeRecording() {
        guard case .paused(let activity) = snapshot.state else { return }
        performedCommands.append(.resume)
        snapshot.state = .recording(activity)
    }

    private func refreshSources() async {
        sourceRefreshCount += 1
        performedCommands.append(.refreshSources)
        guard let sourceProvider else {
            snapshot.applications = scriptedApplications
            snapshot.microphones = scriptedMicrophones
            snapshot.systemDefaultMicrophoneID = scriptedSystemDefaultMicrophoneID
            return
        }
        snapshot.applications = (try? await sourceProvider.shareableApplications()) ?? scriptedApplications
        snapshot.microphones = await sourceProvider.availableMicrophones()
        snapshot.systemDefaultMicrophoneID = await sourceProvider.systemDefaultMicrophone()?.uniqueID
    }

    private func requestPermissions() async {
        permissionRequestCount += 1
        performedCommands.append(.requestPermissions)
        if let permissions {
            snapshot.permissions = await permissions.requestMissingPermissions()
        } else {
            snapshot.permissions = permissionRequestResult
        }
    }

    /// Quitting during capture performs a normal stop first.
    private func quit() {
        quitCount += 1
        performedCommands.append(.quit)
        if snapshot.state.isCapturing {
            stopRecording()
            finishPendingTransition()
        }
        terminationHandler?()
    }
}
