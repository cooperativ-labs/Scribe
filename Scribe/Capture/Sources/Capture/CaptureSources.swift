import Foundation
import Platform
import ScribeAppCore

/// The sources a capture was actually bound to, resolved at start.
public struct ResolvedCaptureSources: Sendable, Equatable {
    /// The bundle identifiers and *current* process identifiers in the content filter.
    public let scope: CaptureScope
    public let applications: [CaptureApplicationOption]
    public let microphone: AudioDeviceIdentity
    /// Human-readable description of the filter, for the journal and the manifest.
    public let filterDescription: String

    public init(scope: CaptureScope, applications: [CaptureApplicationOption], microphone: AudioDeviceIdentity, filterDescription: String) {
        self.scope = scope
        self.applications = applications
        self.microphone = microphone
        self.filterDescription = filterDescription
    }
}

/// Resolves a remembered selection to the processes running right now.
///
/// A content filter is built from one `SCShareableContent` snapshot and never
/// follows the application afterwards: a relaunched process under a new pid is
/// silently never captured, and the stream reports no error, no stop and no
/// timestamp discontinuity while it delivers exact digital silence forever.
/// Resolution therefore happens at every start and fails loudly when the
/// application is gone, rather than broadening capture to all system audio.
/// See [docs/feasibility/capture-timing.md](../../../../docs/feasibility/capture-timing.md).
public enum CaptureSourceResolver {
    /// Every running process a filter naming `bundleIdentifier` would include.
    ///
    /// Helper processes are deliberately not added. ScreenCaptureKit attributes
    /// helper-process audio to the owning application under both the Chromium
    /// child-process model and the WebKit launchd-XPC model, and shared helper
    /// identifiers such as `com.apple.WebKit.GPU` belong to every WebKit host on
    /// the machine, so naming one would capture other applications' media.
    public static func resolveApplication(
        bundleIdentifier: String?,
        among candidates: [CaptureApplicationOption]
    ) throws -> [CaptureApplicationOption] {
        let trimmed = (bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CaptureServiceError.sourceSelection(
                bundleIdentifier: nil,
                message: "No application has been selected to record. Choose one in Scribe's menu, then start again."
            )
        }
        let matches = candidates.filter { $0.bundleIdentifier == trimmed }
        guard !matches.isEmpty else {
            throw CaptureServiceError.sourceSelection(
                bundleIdentifier: trimmed,
                message: "\(trimmed) is not running, so Scribe cannot record it. Open it and start the recording again, "
                    + "or choose a different application. Scribe never falls back to recording all system audio."
            )
        }
        return matches.sorted { ($0.processIdentifier ?? 0) < ($1.processIdentifier ?? 0) }
    }

    /// Resolves the remembered microphone, or the system default when none is
    /// remembered. A remembered device that is no longer connected is an error
    /// rather than a silent fallback: `.microphone` binds its device once at stream
    /// start and never follows the system default, so starting on the wrong input
    /// would record the whole meeting from a device nobody chose.
    public static func resolveMicrophone(
        uniqueID: String?,
        among devices: [CaptureMicrophoneOption],
        systemDefault: CaptureMicrophoneOption?
    ) throws -> AudioDeviceIdentity {
        guard let uniqueID, !uniqueID.isEmpty else {
            guard let systemDefault else {
                throw CaptureServiceError.microphoneUnavailable(
                    uniqueID: nil,
                    message: "No audio input device is available. Connect a microphone, then start the recording again."
                )
            }
            return AudioDeviceIdentity(uniqueID: systemDefault.uniqueID, name: systemDefault.name)
        }
        guard let match = devices.first(where: { $0.uniqueID == uniqueID }) else {
            throw CaptureServiceError.microphoneUnavailable(
                uniqueID: uniqueID,
                message: "The remembered microphone is not connected. Reconnect it, or choose a different microphone, "
                    + "then start the recording again."
            )
        }
        return AudioDeviceIdentity(uniqueID: match.uniqueID, name: match.name)
    }

    public static func describeFilter(displayID: UInt32, bundleIdentifier: String, applications: [CaptureApplicationOption]) -> String {
        let processes = applications
            .map { "\($0.name)(pid \($0.processIdentifier.map(String.init) ?? "unknown"))" }
            .joined(separator: ", ")
        return "display \(displayID) including \(bundleIdentifier) resolved to \(applications.count) process(es): \(processes)"
    }

    public static func scope(bundleIdentifier: String, applications: [CaptureApplicationOption]) -> CaptureScope {
        CaptureScope(
            applicationBundleIdentifiers: [bundleIdentifier],
            processIdentifiers: applications.compactMap(\.processIdentifier)
        )
    }
}
