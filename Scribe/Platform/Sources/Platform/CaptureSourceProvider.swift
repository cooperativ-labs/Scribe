import AVFoundation
import Foundation
import ScreenCaptureKit

/// Enumerates the pickers' contents. Kept behind a protocol so the menu can be
/// exercised without Screen Recording permission or real hardware.
public protocol CaptureSourceProviding: Sendable {
    /// Applications that currently have shareable content.
    func shareableApplications() async throws -> [CaptureApplicationOption]
    /// Audio input devices currently available for capture.
    func availableMicrophones() async -> [CaptureMicrophoneOption]
    /// The device macOS currently treats as the default input, so a "System
    /// Default" choice can say which microphone it will actually record from.
    /// `nil` when no input device exists.
    func systemDefaultMicrophone() async -> CaptureMicrophoneOption?
}

extension CaptureSourceProviding {
    public func systemDefaultMicrophone() async -> CaptureMicrophoneOption? { nil }
}

/// The live provider: `SCShareableContent` for applications, the audio capture
/// discovery session for microphones.
public struct SystemCaptureSourceProvider: CaptureSourceProviding {
    public init() {}

    public func shareableApplications() async throws -> [CaptureApplicationOption] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        return content.applications
            .filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted }
            .map {
                CaptureApplicationOption(
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName.isEmpty ? $0.bundleIdentifier : $0.applicationName,
                    processIdentifier: $0.processID
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func availableMicrophones() async -> [CaptureMicrophoneOption] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { CaptureMicrophoneOption(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    /// The same lookup `CaptureService` uses when it resolves a nil selection at
    /// stream start, so what Settings shows as the default is what gets recorded.
    public func systemDefaultMicrophone() async -> CaptureMicrophoneOption? {
        AVCaptureDevice.default(for: .audio).map { CaptureMicrophoneOption(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }
}
