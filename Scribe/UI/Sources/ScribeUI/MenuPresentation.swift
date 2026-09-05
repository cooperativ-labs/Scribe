import Foundation
import Platform

/// Everything the menu shows, derived from one `RecorderSnapshot` at one instant.
///
/// Keeping this a plain value means every menu state — including the ones that
/// only exist for a moment, like Starting and Stopping — can be produced and
/// asserted without rendering SwiftUI.
public struct MenuPresentation: Equatable, Sendable {
    public let statusTitle: String
    public let statusDetail: String?
    public let statusSymbol: String
    public let isStartEnabled: Bool
    public let isStopEnabled: Bool
    public let isPauseEnabled: Bool
    public let isResumeEnabled: Bool
    /// Which controls the transport row offers: one Record button before a
    /// session exists, and Pause/Resume beside Stop once one does.
    public let transport: TransportControls
    /// Background work, reported separately from capture: the recorder is idle
    /// and ready again while these are still running.
    public let processingLines: [String]
    public let permissionPrompt: PermissionPrompt?
    public let applications: [CaptureApplicationOption]
    public let microphones: [CaptureMicrophoneOption]
    public let selectedApplicationID: String?
    /// `nil` is the system default input, resolved when a recording starts.
    public let selectedMicrophoneID: String?
    /// The device a `nil` microphone selection will record from right now, or
    /// `nil` when the coordinator has not reported one (or no input exists).
    public let systemDefaultMicrophoneName: String?
    public let shortcutIssues: [String]
    /// What launch recovery found, if anything.
    public let recoveryNotice: String?
    public let recordingsFolderName: String

    public init(snapshot: RecorderSnapshot, at date: Date) {
        let permissions = snapshot.permissions
        let isReady = permissions.isReadyToRecord

        switch snapshot.state {
        case .idle:
            statusTitle = "Idle"
            statusDetail = nil
            statusSymbol = "waveform"
        case .starting:
            statusTitle = "Starting…"
            statusDetail = nil
            statusSymbol = "waveform.badge.plus"
        case .recording(let activity):
            statusTitle = "Recording — \(Self.elapsedText(activity.elapsed(at: date)))"
            statusDetail = nil
            statusSymbol = "record.circle"
        case .paused(let activity):
            // The elapsed figure keeps advancing because the recording itself
            // does: a paused span is reconstructed as silence, so this is the
            // length of the file being produced, not just the audible part.
            statusTitle = "Paused — \(Self.elapsedText(activity.elapsed(at: date)))"
            statusDetail = nil
            statusSymbol = "pause.circle"
        case .stopping:
            statusTitle = "Stopping…"
            statusDetail = nil
            statusSymbol = "stop.circle"
        case .failed(let failure):
            statusTitle = "Recording failed"
            statusDetail = [failure.message, failure.recoveryHint].compactMap { $0 }.joined(separator: " ")
            statusSymbol = "exclamationmark.triangle"
        }

        isStartEnabled = isReady && !snapshot.state.isCapturing && !snapshot.state.isTransitioning
        isStopEnabled = snapshot.state.isCapturing
        isPauseEnabled = snapshot.state.isRecording
        isResumeEnabled = snapshot.state.isPaused
        // Stopping keeps the transport row rather than flipping back to Record:
        // the session is still being finalized and cannot be restarted yet.
        transport = snapshot.state.isCapturing || snapshot.state.isTransitioning ? .running : .idle

        var lines = snapshot.processing.jobs.map { job -> String in
            guard let fraction = job.fractionCompleted else { return "\(job.title)…" }
            return "\(job.title) — \(Int((fraction * 100).rounded()))%"
        }
        if let failure = snapshot.processing.lastFailure {
            // The message is already self-describing — a failed cleanup and a
            // refused transcription handoff are different facts and must not be
            // flattened under one prefix.
            lines.append([failure.message, failure.recoveryHint].compactMap { $0 }.joined(separator: " "))
        }
        processingLines = lines

        permissionPrompt = PermissionPrompt(requirements: permissions.blockingRequirements)
        applications = snapshot.applications
        microphones = snapshot.microphones
        selectedApplicationID = snapshot.selectedApplicationID
        selectedMicrophoneID = snapshot.selectedMicrophoneID
        systemDefaultMicrophoneName = snapshot.microphones.first { $0.uniqueID == snapshot.systemDefaultMicrophoneID }?.name
        shortcutIssues = snapshot.shortcutIssues
        recoveryNotice = snapshot.recoveryNotice
        recordingsFolderName = snapshot.recordingsFolderURL.lastPathComponent
    }

    // MARK: Source pickers

    /// The label for the microphone picker's default row. It names the device
    /// so a person can tell what "default" means before recording.
    public var systemDefaultMicrophoneLabel: String {
        guard let systemDefaultMicrophoneName else { return "System Default" }
        return "System Default (\(systemDefaultMicrophoneName))"
    }

    /// A remembered application that is not running right now. It is kept in
    /// the picker as its own row rather than silently clearing the choice, since
    /// a meeting application is usually launched after Scribe.
    public var unavailableSelectedApplication: UnavailableSource? {
        guard let selectedApplicationID, !applications.contains(where: { $0.id == selectedApplicationID }) else { return nil }
        return UnavailableSource(id: selectedApplicationID, label: "\(selectedApplicationID) (not running)")
    }

    /// A remembered microphone that is not connected. Shown rather than
    /// substituted: capture binds the chosen device and never falls back to
    /// another one, so the picker must not pretend a different device is chosen.
    public var unavailableSelectedMicrophone: UnavailableSource? {
        guard let selectedMicrophoneID, !microphones.contains(where: { $0.id == selectedMicrophoneID }) else { return nil }
        return UnavailableSource(id: selectedMicrophoneID, label: "\(selectedMicrophoneID) (not connected)")
    }

    /// `MM:SS` below an hour, `H:MM:SS` above it.
    static func elapsedText(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Which pair of transport controls the menu's top row shows.
///
/// Deliberately not derived from `isStartEnabled` in the view: a Record button
/// that is present but disabled (permissions missing, a start in flight) is a
/// different thing from one replaced by Pause and Stop.
public enum TransportControls: Equatable, Sendable {
    /// One Record button, enabled only when a recording can actually start.
    case idle
    /// Pause or Resume, beside Stop.
    case running
}

/// A remembered source the pickers must keep showing while it is absent.
public struct UnavailableSource: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The first-run and post-denial permission call to action.
///
/// `nil` when nothing is blocking. When a requirement can no longer produce a
/// system prompt, the only offered route is System Settings.
public struct PermissionPrompt: Equatable, Sendable {
    public let requirements: [PermissionRequirement]

    init?(requirements: [PermissionRequirement]) {
        guard !requirements.isEmpty else { return nil }
        self.requirements = requirements
    }

    public var title: String {
        requirements.count == 1
            ? "\(requirements[0].pane.displayName) access is needed"
            : "Scribe needs permission to record"
    }

    /// True while at least one requirement can still be asked for in the app.
    public var canRequestInApp: Bool {
        requirements.contains { $0.canRequestInApp }
    }

    /// Every blocking permission gets a System Settings route, not only the ones
    /// macOS has stopped prompting for: after a denial that is the only way back.
    public var settingsRoutes: [SystemSettingsPane] {
        requirements.map(\.pane)
    }
}
