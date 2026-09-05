import Foundation

// MARK: - Recorder state

/// The capture lifecycle as the menu bar presents it.
///
/// Background processing is deliberately *not* part of this enum: raw capture
/// closes before processing finishes, and a new recording may start while an
/// earlier session is still being processed.
public enum RecorderState: Equatable, Sendable {
    case idle
    case starting
    case recording(RecordingActivity)
    /// Capture is held open but no audio is being archived. The session, its
    /// directory, and its journal all stay alive, so resuming continues the same
    /// recording rather than starting a second one.
    case paused(RecordingActivity)
    case stopping
    case failed(RecorderFailure)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    /// A session exists, running or held. Stop applies to both; start to neither.
    public var isCapturing: Bool { isRecording || isPaused }

    /// Capture is mid-transition; a second command would race the first.
    public var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: true
        case .idle, .recording, .paused, .failed: false
        }
    }

    /// The session being recorded, while there is one.
    public var activity: RecordingActivity? {
        switch self {
        case .recording(let activity), .paused(let activity): activity
        case .idle, .starting, .stopping, .failed: nil
        }
    }
}

/// The identity and start time of the capture currently running.
public struct RecordingActivity: Equatable, Sendable {
    public let sessionID: UUID
    public let startedAt: Date

    public init(sessionID: UUID, startedAt: Date) {
        self.sessionID = sessionID
        self.startedAt = startedAt
    }

    public func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }
}

/// A failure the menu can show without knowing which subsystem produced it.
public struct RecorderFailure: Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoveryHint: String?

    public init(code: String, message: String, recoveryHint: String? = nil) {
        self.code = code
        self.message = message
        self.recoveryHint = recoveryHint
    }
}

// MARK: - Background processing

/// One background job, reported separately from capture so the menu can show
/// "still processing" while the recorder is already idle and ready again.
public struct BackgroundProcessingJob: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    /// `nil` means indeterminate progress.
    public let fractionCompleted: Double?

    public init(id: UUID, title: String, fractionCompleted: Double? = nil) {
        self.id = id
        self.title = title
        self.fractionCompleted = fractionCompleted
    }
}

public struct BackgroundProcessingStatus: Equatable, Sendable {
    public var jobs: [BackgroundProcessingJob]
    public var lastFailure: RecorderFailure?

    public init(jobs: [BackgroundProcessingJob] = [], lastFailure: RecorderFailure? = nil) {
        self.jobs = jobs
        self.lastFailure = lastFailure
    }

    public var isActive: Bool { !jobs.isEmpty }
}

// MARK: - Sources

/// A capturable application enumerated from `SCShareableContent`.
public struct CaptureApplicationOption: Equatable, Sendable, Identifiable, Hashable {
    public let bundleIdentifier: String
    public let name: String
    public let processIdentifier: Int32?

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String, processIdentifier: Int32? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

/// An input device enumerated from the available audio capture devices.
public struct CaptureMicrophoneOption: Equatable, Sendable, Identifiable, Hashable {
    public let uniqueID: String
    public let name: String

    public var id: String { uniqueID }

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

// MARK: - Permissions

public enum PermissionStatus: String, Equatable, Sendable, Codable {
    case notDetermined
    case granted
    case denied

    public var isGranted: Bool { self == .granted }
}

public struct PermissionSnapshot: Equatable, Sendable {
    public var screenAndSystemAudio: PermissionStatus
    public var microphone: PermissionStatus

    public init(screenAndSystemAudio: PermissionStatus = .notDetermined, microphone: PermissionStatus = .notDetermined) {
        self.screenAndSystemAudio = screenAndSystemAudio
        self.microphone = microphone
    }

    public static let allGranted = PermissionSnapshot(screenAndSystemAudio: .granted, microphone: .granted)

    public var isReadyToRecord: Bool {
        screenAndSystemAudio.isGranted && microphone.isGranted
    }
}

/// The System Settings privacy panes Scribe can route the person back to.
public enum SystemSettingsPane: String, Equatable, Sendable, CaseIterable, Identifiable {
    case screenRecording
    case microphone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        }
    }

    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        }
    }
}

// MARK: - Snapshot

/// Everything the menu bar renders, in one value so the UI never reaches into
/// the coordinator's internals and every state is reproducible in a test.
public struct RecorderSnapshot: Equatable, Sendable {
    public var state: RecorderState
    public var processing: BackgroundProcessingStatus
    public var permissions: PermissionSnapshot
    public var applications: [CaptureApplicationOption]
    public var microphones: [CaptureMicrophoneOption]
    public var selectedApplicationID: String?
    /// `nil` means the system default input, resolved at each start.
    public var selectedMicrophoneID: String?
    /// Which of `microphones` macOS currently uses as its default input, so the
    /// pickers can name the device a nil selection will record from.
    public var systemDefaultMicrophoneID: String?
    public var recordingsFolderURL: URL
    /// Human-readable shortcut registration problems; the menu commands stay
    /// usable regardless, so these are informational only.
    public var shortcutIssues: [String]
    /// What launch recovery found, if anything. Shown so a person learns that an
    /// interrupted meeting survived rather than having to discover it in Finder.
    public var recoveryNotice: String?

    public init(
        state: RecorderState = .idle,
        processing: BackgroundProcessingStatus = BackgroundProcessingStatus(),
        permissions: PermissionSnapshot = PermissionSnapshot(),
        applications: [CaptureApplicationOption] = [],
        microphones: [CaptureMicrophoneOption] = [],
        selectedApplicationID: String? = nil,
        selectedMicrophoneID: String? = nil,
        recordingsFolderURL: URL = ScribeSettings.defaultRecordingsFolderURL,
        shortcutIssues: [String] = [],
        recoveryNotice: String? = nil,
        systemDefaultMicrophoneID: String? = nil
    ) {
        self.state = state
        self.processing = processing
        self.permissions = permissions
        self.applications = applications
        self.microphones = microphones
        self.selectedApplicationID = selectedApplicationID
        self.selectedMicrophoneID = selectedMicrophoneID
        self.recordingsFolderURL = recordingsFolderURL
        self.shortcutIssues = shortcutIssues
        self.recoveryNotice = recoveryNotice
        self.systemDefaultMicrophoneID = systemDefaultMicrophoneID
    }
}

// MARK: - Commands

/// Every user intent, from the menu or from a global shortcut, expressed as one
/// value so both entry points travel the same serialized path.
public enum RecordingCommand: Equatable, Sendable {
    case start
    case stop
    /// Holds an active capture without finalizing it. The paused span becomes
    /// silence in the reconstructed recording, so both tracks stay aligned.
    case pause
    case resume
    case selectApplication(String?)
    case selectMicrophone(String?)
    case refreshSources
    case openRecordingsFolder
    case requestPermissions
    case openSystemSettings(SystemSettingsPane)
    case quit
}

// MARK: - Coordinator

/// Cancels a snapshot subscription when invalidated or released.
///
/// The token is intentionally not main-actor isolated so that `deinit` can run
/// wherever the subscriber is released; cancellation hops back to the main actor.
public final class RecorderObservationToken: Sendable {
    private let id: UUID
    /// Held strongly: the broadcaster owns only closures, never the token, so
    /// this cannot form a cycle, and a `weak` field is not allowed on a
    /// `Sendable` class.
    private let broadcaster: RecorderSnapshotBroadcaster

    init(id: UUID, broadcaster: RecorderSnapshotBroadcaster) {
        self.id = id
        self.broadcaster = broadcaster
    }

    /// Stops delivery immediately; no snapshot published after this call is seen.
    @MainActor
    public func invalidate() { broadcaster.removeObserver(id) }

    deinit {
        let (id, broadcaster) = (self.id, self.broadcaster)
        Task { @MainActor in broadcaster.removeObserver(id) }
    }
}

/// Fans a snapshot out to the menu and any other subscriber.
///
/// Coordinator implementations own one of these so observation behaves
/// identically for the mock and for the capture-backed coordinator.
@MainActor
public final class RecorderSnapshotBroadcaster {
    private var observers: [UUID: @MainActor (RecorderSnapshot) -> Void] = [:]

    public init() {}

    public func addObserver(_ observer: @escaping @MainActor (RecorderSnapshot) -> Void) -> RecorderObservationToken {
        let id = UUID()
        observers[id] = observer
        return RecorderObservationToken(id: id, broadcaster: self)
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    public func publish(_ snapshot: RecorderSnapshot) {
        for observer in observers.values {
            observer(snapshot)
        }
    }
}

/// The single boundary the menu bar and the global shortcuts talk to.
///
/// Conforming types must execute commands one at a time and must treat
/// redundant commands (start while recording, stop while idle) as no-ops.
@MainActor
public protocol RecordingCoordinating: RecordingShortcutCoordinating {
    var snapshot: RecorderSnapshot { get }

    /// Submits a command for serialized execution. Never blocks the caller.
    func submit(_ command: RecordingCommand)

    /// Publishes shortcut registration results so the menu can show conflicts.
    func reportShortcutRegistration(_ report: HotkeyRegistrationReport)

    /// Observes snapshot changes. The observer is called immediately with the
    /// current snapshot so subscribers never render a stale first frame.
    func observeSnapshot(_ observer: @escaping @MainActor (RecorderSnapshot) -> Void) -> RecorderObservationToken
}

extension RecordingCoordinating {
    /// Shortcuts deliberately reuse `submit` rather than a private entry point:
    /// menu and keyboard commands must not be able to interleave differently.
    public func startRecordingFromShortcut() { submit(.start) }
    public func stopRecordingFromShortcut() { submit(.stop) }
}
