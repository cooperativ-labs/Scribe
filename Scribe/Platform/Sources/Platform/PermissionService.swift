import Foundation

/// One permission that stands between the person and a recording, together with
/// the route that fixes it.
///
/// `PermissionStatus`, `PermissionSnapshot` and `SystemSettingsPane` are declared
/// alongside the menu-bar contracts in `RecordingCoordinator.swift`; this file adds
/// the service that reads them, notices revocation, and says what to do next.
public struct PermissionRequirement: Equatable, Sendable, Identifiable {
    public let pane: SystemSettingsPane
    public let status: PermissionStatus
    /// Whether asking from inside the app can still produce a system prompt. Once
    /// this is false, System Settings is the only remaining route.
    public let canRequestInApp: Bool
    public let message: String

    public var id: String { pane.rawValue }
    public var settingsURL: URL { pane.settingsURL }

    public init(pane: SystemSettingsPane, status: PermissionStatus, canRequestInApp: Bool, message: String) {
        self.pane = pane
        self.status = status
        self.canRequestInApp = canRequestInApp
        self.message = message
    }
}

/// A permission that was granted and no longer is.
///
/// This is the case a recording must survive: a TCC decision can be withdrawn at
/// any moment, and neither ScreenCaptureKit nor AVFoundation reports the change
/// until capture has already failed.
public struct PermissionRevocation: Equatable, Sendable {
    public let pane: SystemSettingsPane
    public let currentStatus: PermissionStatus
    public let observedAt: Date

    public init(pane: SystemSettingsPane, currentStatus: PermissionStatus, observedAt: Date) {
        self.pane = pane
        self.currentStatus = currentStatus
        self.observedAt = observedAt
    }

    public var failure: RecorderFailure {
        RecorderFailure(
            code: "permission.revoked.\(pane.rawValue)",
            message: "\(pane.displayName) access was withdrawn while Scribe was using it.",
            recoveryHint: "Re-enable Scribe in System Settings > Privacy & Security > \(pane.displayName), then start a new recording."
        )
    }
}

public extension PermissionSnapshot {
    /// Everything that must change before a recording can start, in the order to
    /// ask. Empty when both permissions are granted.
    var blockingRequirements: [PermissionRequirement] {
        SystemSettingsPane.allCases.compactMap { pane in
            let status = self.status(of: pane)
            guard !status.isGranted else { return nil }
            return PermissionRequirement(
                pane: pane,
                status: status,
                // macOS prompts for the microphone only while it is undetermined.
                // `CGRequestScreenCaptureAccess` may still be worth calling for a
                // bundled app that has never asked, and reports `denied` either way.
                canRequestInApp: status == .notDetermined || pane == .screenRecording,
                message: Self.message(for: pane, status: status)
            )
        }
    }

    func status(of pane: SystemSettingsPane) -> PermissionStatus {
        switch pane {
        case .screenRecording: screenAndSystemAudio
        case .microphone: microphone
        }
    }

    /// The blocking requirements as one failure the menu can present directly.
    var blockingFailure: RecorderFailure? {
        let requirements = blockingRequirements
        guard let first = requirements.first else { return nil }
        return RecorderFailure(
            code: "permission.missing." + requirements.map(\.pane.rawValue).joined(separator: "+"),
            message: requirements.map(\.message).joined(separator: " "),
            recoveryHint: "Open System Settings > Privacy & Security > \(first.pane.displayName)."
        )
    }

    private static func message(for pane: SystemSettingsPane, status: PermissionStatus) -> String {
        switch (pane, status) {
        case (.screenRecording, _):
            "Scribe cannot record system audio until Screen & System Audio Recording is enabled for it. "
                + "macOS may require quitting and reopening Scribe after the switch is turned on."
        case (.microphone, .notDetermined):
            "Scribe has not asked for microphone access yet."
        case (.microphone, _):
            "Microphone access was declined, so Scribe cannot record your voice."
        }
    }
}

/// Reads and requests the capture permissions, notices when one is withdrawn, and
/// hands out the System Settings route once in-app requesting can no longer help.
///
/// Nothing is cached as authoritative: every check goes to the system. The retained
/// snapshot exists only to recognize the *transition* from granted to not granted,
/// because macOS posts no notification when a TCC decision changes and polling is
/// the only signal available.
public final class PermissionService: RecordingPermissionProviding, @unchecked Sendable {
    private let provider: RecordingPermissionProviding
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var lastSnapshot: PermissionSnapshot?
    private var revocationHandler: (@Sendable (PermissionRevocation) -> Void)?
    private var monitor: DispatchSourceTimer?

    public init(
        provider: RecordingPermissionProviding = SystemRecordingPermissions(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.provider = provider
        self.clock = clock
    }

    deinit { monitor?.cancel() }

    /// Reads both permissions and reports any that were granted the last time this
    /// service looked and are not granted now.
    @discardableResult
    public func currentStatus() -> PermissionSnapshot {
        record(provider.currentStatus())
    }

    /// Triggers whichever system prompts are still available, then reports what
    /// remains blocking. Anything still listed afterwards needs System Settings.
    public func requestMissingPermissions() async -> PermissionSnapshot {
        record(await provider.requestMissingPermissions())
    }

    @MainActor
    public func openSystemSettings(_ pane: SystemSettingsPane) {
        provider.openSystemSettings(pane)
    }

    /// The last snapshot read, without touching the system again.
    public var lastKnownSnapshot: PermissionSnapshot? { lock.withLock { lastSnapshot } }

    /// Installs the callback used to report a permission that stops being granted.
    public func observeRevocations(_ handler: @escaping @Sendable (PermissionRevocation) -> Void) {
        lock.withLock { revocationHandler = handler }
    }

    /// Polls both permissions on `queue`. TCC posts no notification when a decision
    /// changes, so polling is the only way to notice a mid-recording revocation.
    public func startMonitoring(
        interval: TimeInterval = 5,
        queue: DispatchQueue = DispatchQueue(label: "io.cooperativ.scribe.permissions", qos: .utility)
    ) {
        stopMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in _ = self?.currentStatus() }
        timer.resume()
        lock.withLock { monitor = timer }
    }

    public func stopMonitoring() {
        let existing = lock.withLock { () -> DispatchSourceTimer? in
            let current = monitor
            monitor = nil
            return current
        }
        existing?.cancel()
    }

    private func record(_ snapshot: PermissionSnapshot) -> PermissionSnapshot {
        let now = clock()
        let (revocations, handler) = lock.withLock { () -> ([PermissionRevocation], (@Sendable (PermissionRevocation) -> Void)?) in
            let previous = lastSnapshot
            lastSnapshot = snapshot
            guard let previous else { return ([], revocationHandler) }
            let withdrawn = SystemSettingsPane.allCases.compactMap { pane -> PermissionRevocation? in
                guard previous.status(of: pane).isGranted, !snapshot.status(of: pane).isGranted else { return nil }
                return PermissionRevocation(pane: pane, currentStatus: snapshot.status(of: pane), observedAt: now)
            }
            return (withdrawn, revocationHandler)
        }
        for revocation in revocations { handler?(revocation) }
        return snapshot
    }
}
