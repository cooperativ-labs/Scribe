import AVFoundation
import CoreMedia
import Foundation
import Platform
import ScribeAppCore
import Storage

/// Captures one selected microphone without creating a ScreenCaptureKit stream.
///
/// `AVCaptureSession` is intentionally separate from `CaptureService`: it avoids
/// both application selection and the Screen & System Audio Recording permission,
/// while keeping the same owned-buffer and event contracts used by durable capture.
final class MicrophoneCaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, RecordingCaptureControlling, @unchecked Sendable {
    private let microphoneUniqueID: String?
    private let sourceProvider: any CaptureSourceProviding
    private let sink: @Sendable (OwnedPCMBuffer) -> Void
    private let events: @Sendable (CaptureEvent) -> Void
    private let sampleQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.microphone-only.samples", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "io.cooperativ.scribe.capture.microphone-only.writer", qos: .userInitiated)
    private let buffers = BoundedBufferQueue(maximumBytes: 4 * 1_024 * 1_024)
    private let lock = NSLock()

    private var session: AVCaptureSession?
    private var isPaused = false
    private var rejectedBuffers = 0

    init(
        microphoneUniqueID: String?,
        sourceProvider: any CaptureSourceProviding,
        sink: @escaping @Sendable (OwnedPCMBuffer) -> Void,
        events: @escaping @Sendable (CaptureEvent) -> Void
    ) {
        self.microphoneUniqueID = microphoneUniqueID
        self.sourceProvider = sourceProvider
        self.sink = sink
        self.events = events
    }

    func start() async throws -> ResolvedCaptureSources {
        guard lock.withLock({ session == nil }) else { throw CaptureServiceError.alreadyRunning }
        let microphone = try CaptureSourceResolver.resolveMicrophone(
            uniqueID: microphoneUniqueID,
            among: await sourceProvider.availableMicrophones(),
            systemDefault: AVCaptureDevice.default(for: .audio).map {
                CaptureMicrophoneOption(uniqueID: $0.uniqueID, name: $0.localizedName)
            }
        )
        guard let device = AVCaptureDevice(uniqueID: microphone.uniqueID) else {
            throw CaptureServiceError.microphoneUnavailable(
                uniqueID: microphone.uniqueID,
                message: "The selected microphone is no longer available. Choose a different microphone, then start again."
            )
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureServiceError.streamStartFailed("macOS could not configure the selected microphone.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        lock.withLock { self.session = session }

        let sources = ResolvedCaptureSources(
            scope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
            applications: [],
            microphone: microphone,
            filterDescription: "microphone only: \(microphone.name)"
        )
        emit(.started(sources))
        return sources
    }

    func setPaused(_ paused: Bool) {
        lock.withLock { isPaused = paused }
    }

    func stop() async -> CaptureStatistics {
        let active = lock.withLock { () -> AVCaptureSession? in
            let current = session
            session = nil
            return current
        }
        active?.stopRunning()
        sampleQueue.sync {}
        writerQueue.sync { drain() }
        emit(.stopped)
        let microphone = buffers.snapshot
        return CaptureStatistics(
            // A silent system reference is archived beside each microphone buffer
            // so the established reconstruction and mixdown pipeline can preserve
            // timing without treating this valid mode as a missing-track failure.
            system: microphone,
            microphone: microphone,
            rejectedBuffers: lock.withLock { rejectedBuffers },
            discardedScreenFrames: 0
        )
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !lock.withLock({ isPaused }) else { return }
        guard let buffer = CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: .microphone) else {
            writerQueue.async { [weak self] in
                guard let self else { return }
                lock.withLock { rejectedBuffers += 1 }
                events(.bufferRejected(track: .microphone))
            }
            return
        }
        let accepted = buffers.enqueue(buffer)
        writerQueue.async { [weak self] in
            guard let self else { return }
            if !accepted { events(.buffersDropped(track: .microphone, count: buffers.snapshot.droppedBuffers)) }
            drain()
        }
    }

    private func drain() {
        for buffer in buffers.drain() {
            // Processing expects a system timeline as the echo-cancellation
            // reference. A same-shaped zero buffer says precisely what happened:
            // there was no system source, while keeping both tracks aligned.
            if let silentReference = try? OwnedPCMBuffer(
                track: .system,
                presentationTimestampSeconds: buffer.presentationTimestampSeconds,
                format: buffer.format,
                frameCount: buffer.frameCount,
                samples: Data(repeating: 0, count: buffer.samples.count)
            ) {
                sink(silentReference)
            }
            sink(buffer)
        }
    }

    private func emit(_ event: CaptureEvent) {
        writerQueue.async { [events] in events(event) }
    }
}
