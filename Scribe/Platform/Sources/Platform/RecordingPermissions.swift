import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Performs the raw operating-system permission calls.
///
/// `PermissionService` layers revocation detection and monitoring on top of this;
/// the protocol exists so both can be exercised without a real TCC database.
public protocol RecordingPermissionProviding: Sendable {
    func currentStatus() -> PermissionSnapshot
    /// Triggers the system prompts that are still available, then reports the
    /// resulting status. macOS does not re-prompt for a denied permission.
    func requestMissingPermissions() async -> PermissionSnapshot
    @MainActor func openSystemSettings(_ pane: SystemSettingsPane)
}

public struct SystemRecordingPermissions: RecordingPermissionProviding {
    public init() {}

    public func currentStatus() -> PermissionSnapshot {
        PermissionSnapshot(
            screenAndSystemAudio: Self.screenRecordingStatus(),
            microphone: MicrophonePermission.currentStatus()
        )
    }

    public func requestMissingPermissions() async -> PermissionSnapshot {
        if Self.screenRecordingStatus() != .granted {
            // macOS shows this prompt once; afterwards it returns false with no
            // prompt and the person has to grant access in System Settings.
            _ = CGRequestScreenCaptureAccess()
        }
        await MicrophonePermission.requestIfNeeded()
        return currentStatus()
    }

    @MainActor
    public func openSystemSettings(_ pane: SystemSettingsPane) {
        NSWorkspace.shared.open(pane.settingsURL)
    }

    /// CoreGraphics only distinguishes granted from not granted, so an unasked
    /// state is indistinguishable from a refusal and is reported as denied.
    private static func screenRecordingStatus() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }
}

/// Shared by recording and dictation so both paths interpret and request access alike.
enum MicrophonePermission {
    static func currentStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestIfNeeded() async {
        if currentStatus() == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
