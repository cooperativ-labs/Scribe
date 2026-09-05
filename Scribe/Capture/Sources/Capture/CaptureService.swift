import AVFoundation
import AppKit
import CoreMedia
import Foundation
import Platform
import ScreenCaptureKit
import ScribeAppCore
import Storage

/// What a capture reports while it runs. Every case is a fact observed from the
/// stream, not an inference from audio level: a filter matching a silent
/// application and a filter whose application has died both deliver a continuous
/// stream of exactly-zero samples, so loudness can neither confirm nor diagnose a
/// capture.
public enum CaptureEvent: Sendable {
    case started(ResolvedCaptureSources)
    /// A buffer arrived in a different format from the previous one on that track.
    case formatChanged(track: RecorderTrackKind, from: PCMFormat, to: PCMFormat)
    /// A buffer could not be interpreted as linear PCM and was not archived.
    case bufferRejected(track: RecorderTrackKind)
    /// The bounded hand-off queue was full. `count` is the running total.
    case buffersDropped(track: RecorderTrackKind, count: Int)
    /// `SCStreamDelegate.stream(_:didStopWithError:)`. The stream is gone.
    case streamFailed(RecorderFailure)
    case stopped
}

public enum CaptureServiceError: LocalizedError, Equatable {
    case sourceSelection(bundleIdentifier: String?, message: String)
    case microphoneUnavailable(uniqueID: String?, message: String)
    case screenRecordingPermissionDenied(underlying: String)
    case noDisplay
    case shareableContent(String)
    case streamStartFailed(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case let .sourceSelection(_, message): message
        case let .microphoneUnavailable(_, message): message
        case .screenRecordingPermissionDenied:
            "Scribe does not have Screen & System Audio Recording permission, so it cannot record system audio."
        case .noDisplay:
            "macOS reported no display. A content filter always requires a display, even for an audio-only recording."
        case let .shareableContent(message):
            "Scribe could not read the list of capturable applications: \(message)"
        case let .streamStartFailed(message):
            "The capture stream did not start: \(message)"
        case .alreadyRunning:
            "A capture is already running."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case let .sourceSelection(_, message): message
        case let .microphoneUnavailable(_, message): message
        case .screenRecordingPermissionDenied:
            "Enable Scribe in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen Scribe."
        case .noDisplay:
            "Reconnect a display, or wake the Mac, and start the recording again."
        case .shareableContent:
            "Check Scribe's Screen & System Audio Recording permission in System Settings, then try again."
        case .streamStartFailed, .alreadyRunning:
            nil
        }
    }

    /// The same error as the menu-bar failure value, so a caller never has to
    /// re-word it. Every case carries a route the person can act on.
    public var failure: RecorderFailure {
        RecorderFailure(code: code, message: errorDescription ?? "Capture failed.", recoveryHint: recoverySuggestion)
    }

    private var code: String {
        switch self {
        case .sourceSelection: "capture.sourceSelection"
        case .microphoneUnavailable: "capture.microphoneUnavailable"
        case .screenRecordingPermissionDenied: "capture.permissionDenied"
        case .noDisplay: "capture.noDisplay"
        case .shareableContent: "capture.shareableContent"
        case .streamStartFailed: "capture.streamStartFailed"
        case .alreadyRunning: "capture.alreadyRunning"
        }
    }

    /// Recognizes the TCC refusal `SCShareableContent` reports when Screen &
    /// System Audio Recording is missing or has been revoked. macOS surfaces this
    /// as a generic content error, so the message is the only discriminator; when
    /// it does not match, the caller still gets an actionable content error.
    static func classifyShareableContentFailure(_ error: Error) -> CaptureServiceError {
        let nsError = error as NSError
        let text = "\(nsError.localizedDescription) \(nsError.debugDescription)".lowercased()
        let isTCC = nsError.domain == SCStreamError.errorDomain
            && (nsError.code == SCStreamError.Code.userDeclined.rawValue || nsError.code == SCStreamError.Code.missingEntitlements.rawValue)
        if isTCC || text.contains("declined") || text.contains("tcc") || text.contains("not authorized") || text.contains("permission") {
            return .screenRecordingPermissionDenied(underlying: nsError.localizedDescription)
        }
        return .shareableContent(nsError.localizedDescription)
    }
}

public struct CaptureConfiguration: Sendable {
    /// The remembered application. Resolved to its current process at every start.
    public var applicationBundleIdentifier: String?
    /// The remembered microphone, or nil for the system default input.
    public var microphoneUniqueID: String?
    public var sampleRate: Int
    public var channelCount: Int
    /// Byte budget for the hand-off between the sample handlers and the writer.
    public var maximumQueuedBytes: Int
    /// Register a discardable minimal screen output.
    ///
    /// Audio-only operation was measured working on every one of ten `SCStream`
    /// runs with no `.screen` output registered at all, so this stays off. The
    /// plan's fallback remains available for a configuration that needs it.
    public var registersMinimalScreenOutput: Bool

    public init(
        applicationBundleIdentifier: String?,
        microphoneUniqueID: String? = nil,
        sampleRate: Int = 48_000,
        channelCount: Int = 1,
        maximumQueuedBytes: Int = 4 * 1_024 * 1_024,
        registersMinimalScreenOutput: Bool = false
    ) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.microphoneUniqueID = microphoneUniqueID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maximumQueuedBytes = maximumQueuedBytes
        self.registersMinimalScreenOutput = registersMinimalScreenOutput
    }
}

public struct CaptureStatistics: Sendable, Equatable {
    public var system: BoundedBufferQueue.Statistics
    public var microphone: BoundedBufferQueue.Statistics
    public var rejectedBuffers: Int
    public var discardedScreenFrames: Int

    public var droppedBuffers: Int { system.droppedBuffers + microphone.droppedBuffers }
    public var hasBothTracks: Bool { system.enqueuedBuffers > 0 && microphone.enqueuedBuffers > 0 }
}

/// One `SCStream` carrying `.audio` and `.microphone`, delivered as owned PCM.
///
/// Sample handlers run on two explicit serial queues and do nothing but validate
/// the buffer, copy its samples into bounded storage, and enqueue. All archiving
/// happens on a third serial queue, so no disk work ever runs on a capture
/// callback and no `CMSampleBuffer` escapes the handler that received it.
public final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let configuration: CaptureConfiguration
    private let sourceProvider: CaptureSourceProviding
    private let sink: @Sendable (OwnedPCMBuffer) -> Void
    private let events: @Sendable (CaptureEvent) -> Void

    private let systemQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.system", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.microphone", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.screen", qos: .utility)
    private let writerQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.writer", qos: .userInitiated)

    private let systemBuffers: BoundedBufferQueue
    private let microphoneBuffers: BoundedBufferQueue

    private let lock = NSLock()
    private var stream: SCStream?
    private var lastFormats: [RecorderTrackKind: PCMFormat] = [:]
    private var rejectedBuffers = 0
    private var discardedScreenFrames = 0
    private var resolvedSources: ResolvedCaptureSources?
    private var isPaused = false

    /// - Parameters:
    ///   - sink: receives every archived buffer on the writer queue, in arrival
    ///     order per track. Typically `SessionStore.append`.
    ///   - events: receives capture events on the writer queue.
    public init(
        configuration: CaptureConfiguration,
        sourceProvider: CaptureSourceProviding = SystemCaptureSourceProvider(),
        sink: @escaping @Sendable (OwnedPCMBuffer) -> Void,
        events: @escaping @Sendable (CaptureEvent) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.sourceProvider = sourceProvider
        self.sink = sink
        self.events = events
        systemBuffers = BoundedBufferQueue(maximumBytes: configuration.maximumQueuedBytes)
        microphoneBuffers = BoundedBufferQueue(maximumBytes: configuration.maximumQueuedBytes)
        super.init()
    }

    public var statistics: CaptureStatistics {
        let (rejected, screenFrames) = lock.withLock { (rejectedBuffers, discardedScreenFrames) }
        return CaptureStatistics(
            system: systemBuffers.snapshot,
            microphone: microphoneBuffers.snapshot,
            rejectedBuffers: rejected,
            discardedScreenFrames: screenFrames
        )
    }

    public var sources: ResolvedCaptureSources? { lock.withLock { resolvedSources } }

    // MARK: - Lifecycle

    /// Resolves the sources, configures the stream, and starts capture. Throws an
    /// actionable error rather than recording something other than what was asked for.
    @discardableResult
    public func start() async throws -> ResolvedCaptureSources {
        guard lock.withLock({ stream == nil }) else { throw CaptureServiceError.alreadyRunning }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureServiceError.classifyShareableContentFailure(error)
        }
        guard let display = content.displays.first else { throw CaptureServiceError.noDisplay }

        let candidates = content.applications.map {
            CaptureApplicationOption(
                bundleIdentifier: $0.bundleIdentifier,
                name: $0.applicationName.isEmpty ? $0.bundleIdentifier : $0.applicationName,
                processIdentifier: $0.processID
            )
        }
        let matches = try CaptureSourceResolver.resolveApplication(
            bundleIdentifier: configuration.applicationBundleIdentifier,
            among: candidates
        )
        let bundleIdentifier = matches[0].bundleIdentifier
        let microphone = try CaptureSourceResolver.resolveMicrophone(
            uniqueID: configuration.microphoneUniqueID,
            among: await sourceProvider.availableMicrophones(),
            systemDefault: AVCaptureDevice.default(for: .audio).map {
                CaptureMicrophoneOption(uniqueID: $0.uniqueID, name: $0.localizedName)
            }
        )

        let matchedPIDs = Set(matches.compactMap(\.processIdentifier))
        let runningApplications = content.applications.filter { matchedPIDs.contains($0.processID) }
        let filter = SCContentFilter(display: display, including: runningApplications, exceptingWindows: [])

        let sources = ResolvedCaptureSources(
            scope: CaptureSourceResolver.scope(bundleIdentifier: bundleIdentifier, applications: matches),
            applications: matches,
            microphone: microphone,
            filterDescription: CaptureSourceResolver.describeFilter(
                displayID: display.displayID,
                bundleIdentifier: bundleIdentifier,
                applications: matches
            )
        )

        let stream = SCStream(filter: filter, configuration: makeConfiguration(microphoneID: microphone.uniqueID), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
            if configuration.registersMinimalScreenOutput {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
            }
            try await stream.startCapture()
        } catch {
            throw CaptureServiceError.streamStartFailed(error.localizedDescription)
        }

        lock.withLock {
            self.stream = stream
            self.resolvedSources = sources
        }
        emit(.started(sources))
        return sources
    }

    /// Holds or resumes archiving without touching the stream.
    ///
    /// The `SCStream` keeps running: tearing it down and rebuilding it would
    /// rebind the microphone and re-resolve the application, which is exactly
    /// what a pause must not do. Buffers that arrive while paused are dropped in
    /// the sample handler, before any copy, so a long pause costs nothing and
    /// leaves no partial audio behind. The resulting timestamp discontinuity is
    /// journaled as an ordinary gap, and the reconstruction fills it with
    /// silence on both tracks, so the two stay aligned across the pause.
    public func setPaused(_ paused: Bool) {
        lock.withLock { isPaused = paused }
    }

    /// Stops the stream, then drains both hand-off queues so that every buffer
    /// which already reached a callback is archived before this returns.
    public func stop() async -> CaptureStatistics {
        let active = lock.withLock { () -> SCStream? in
            let current = stream
            stream = nil
            return current
        }
        if let active {
            try? await active.stopCapture()
        }
        // Two barriers: the sample handlers may still be mid-copy on their own
        // queues, and their enqueued work has to land on the writer before the
        // final drain closes the files.
        systemQueue.sync {}
        microphoneQueue.sync {}
        writerQueue.sync { self.drain(.system) }
        writerQueue.sync { self.drain(.microphone) }
        emit(.stopped)
        return statistics
    }

    private func makeConfiguration(microphoneID: String) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = self.configuration.sampleRate
        configuration.channelCount = self.configuration.channelCount
        // Scribe's own output must never be recaptured into the meeting.
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        // The microphone binds its device here, once, and does not follow the
        // system default afterwards.
        configuration.microphoneCaptureDeviceID = microphoneID
        // No screen frames are ever saved. The frame configuration stays at its
        // smallest so a stream that insists on producing frames costs almost nothing.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        return configuration
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        emit(.streamFailed(RecorderFailure(
            code: "capture.streamStopped",
            message: "The capture stream stopped: \(error.localizedDescription)",
            recoveryHint: "Scribe is finalizing what it recorded. Start a new recording to continue."
        )))
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            ingest(sampleBuffer, track: .system)
        case .microphone:
            ingest(sampleBuffer, track: .microphone)
        case .screen:
            // Discarded on arrival; nothing is retained and no frame is written.
            writerQueue.async { [weak self] in
                guard let self else { return }
                lock.withLock { discardedScreenFrames += 1 }
            }
        @unknown default:
            return
        }
    }

    /// Everything a sample handler does: validate, copy, enqueue -- nothing else.
    ///
    /// Reachable without an `SCStream` so the whole delivery path, from a real
    /// `CMSampleBuffer` through to the sink, can be exercised without a Screen &
    /// System Audio Recording grant.
    func ingest(_ sampleBuffer: CMSampleBuffer, track: RecorderTrackKind) {
        // Dropped before the copy: a paused capture must not accumulate audio,
        // and a rejected-buffer count would be a lie about the stream's health.
        guard !lock.withLock({ isPaused }) else { return }
        let queue = track == .system ? systemBuffers : microphoneBuffers
        guard let owned = CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: track) else {
            writerQueue.async { [weak self] in
                guard let self else { return }
                lock.withLock { rejectedBuffers += 1 }
                events(.bufferRejected(track: track))
            }
            return
        }
        let accepted = queue.enqueue(owned)
        writerQueue.async { [weak self] in
            guard let self else { return }
            if !accepted {
                events(.buffersDropped(track: track, count: queue.snapshot.droppedBuffers))
            }
            drain(track)
        }
    }

    /// Runs on the writer queue. Archives everything queued for one track and
    /// reports any format change the buffers themselves show.
    private func drain(_ track: RecorderTrackKind) {
        let queue = track == .system ? systemBuffers : microphoneBuffers
        for buffer in queue.drain() {
            let previous = lock.withLock { () -> PCMFormat? in
                let existing = lastFormats[track]
                lastFormats[track] = buffer.format
                return existing
            }
            if let previous, previous != buffer.format {
                events(.formatChanged(track: track, from: previous, to: buffer.format))
            }
            sink(buffer)
        }
    }

    private func emit(_ event: CaptureEvent) {
        writerQueue.async { [events] in events(event) }
    }
}
