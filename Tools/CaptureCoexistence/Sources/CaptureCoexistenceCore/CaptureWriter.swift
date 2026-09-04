import Foundation
import ScribeAppCore
import Storage

/// Drives the recorder's real archiving path at real capture cadence and
/// records every gap it produces.
///
/// The shape is `CaptureService`'s: a sample handler that only copies and
/// enqueues into a bounded buffer, and a separate serial writer queue that
/// drains it into a real `SessionStore`. That structure is the whole reason a
/// slow disk does not lose audio, so a harness that wrote synchronously on the
/// capture thread would measure something the recorder never does.
///
/// A gap is therefore defined exactly as the recorder defines one: a buffer the
/// bounded queue refused because the writer had fallen too far behind. Producer
/// jitter is reported separately, because a late but accepted buffer costs no
/// audio.
///
/// `SCStream` is the only thing stood in for. It cannot be granted Screen &
/// System Audio Recording to a command-line tool, so buffers are synthesized at
/// exactly the rate and in exactly the layouts it was measured to deliver.
public final class CaptureWriter: @unchecked Sendable {
    public struct Report: Sendable {
        public var deliveredBuffers = 0
        /// Buffers the bounded queue refused: real lost audio.
        public var gaps = 0
        public var gapsBeforeBoundary = 0
        public var gapsAfterBoundary = 0
        /// Producer wake-ups later than one buffer period. Informational: a late
        /// buffer that still fits in the queue loses nothing.
        public var lateWakeups = 0
        public var worstLatenessMilliseconds = 0.0
        public var peakQueuedBytes = 0
        public var writeFailures: [String] = []
        /// Gaps by elapsed minute. A single burst and a progressive decline are
        /// different diagnoses, and two half-totals cannot tell them apart.
        public var gapsByMinute: [Int: Int] = [:]

        public var isClean: Bool { gaps == 0 && writeFailures.isEmpty }
    }

    /// The layouts measured in docs/feasibility/capture-timing.md: 960 frames of
    /// 48 kHz stereo system audio, 512 frames of 48 kHz mono microphone.
    public static let systemFrames = 960
    public static let microphoneFrames = 512
    public static let sampleRate: Double = 48_000
    public static var bufferInterval: TimeInterval { Double(systemFrames) / sampleRate }
    /// `CaptureConfiguration`'s default bound, so the queue fills when the
    /// recorder's would.
    public static let maximumQueuedBytes = 4 * 1_024 * 1_024

    private let store: SessionStore
    private let writerQueue = DispatchQueue(label: "io.cooperativ.scribe.coexistence.writer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [OwnedPCMBuffer] = []
    private var queuedBytes = 0
    private var state = Report()

    private let systemFormat = PCMFormat(sampleRate: sampleRate, channelCount: 2, bitsPerChannel: 32, isFloat: true)
    private let microphoneFormat = PCMFormat(sampleRate: sampleRate, channelCount: 1, bitsPerChannel: 32, isFloat: true)
    private let systemSamples: Data
    private let microphoneSamples: Data

    public init(store: SessionStore) {
        self.store = store
        systemSamples = Self.samples(frames: Self.systemFrames, channels: 2)
        microphoneSamples = Self.samples(frames: Self.microphoneFrames, channels: 1)
    }

    /// Records for `seconds`, calling `atElapsed` once per second so a caller
    /// can change the world part-way through a single recording.
    ///
    /// `atElapsed` must not block: capture never waits for background work, and
    /// a callback that did would measure the harness rather than the product.
    public func record(
        seconds: TimeInterval,
        boundary: TimeInterval,
        atElapsed: @Sendable (TimeInterval) -> Void
    ) async throws -> Report {
        let started = Date()
        var systemIndex = 0
        var microphoneIndex = 0
        var lastCallbackSecond = -1

        while true {
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed < seconds else { break }

            let due = started.addingTimeInterval(Double(systemIndex) * Self.bufferInterval)
            let sleepFor = due.timeIntervalSinceNow
            if sleepFor > 0 { try? await Task.sleep(for: .seconds(sleepFor)) }

            let lateness = Date().timeIntervalSince(due)
            if lateness > Self.bufferInterval {
                lock.withLock {
                    state.lateWakeups += 1
                    state.worstLatenessMilliseconds = max(state.worstLatenessMilliseconds, lateness * 1_000)
                }
            }

            let mediaTime = Double(systemIndex * Self.systemFrames) / Self.sampleRate
            ingest(try OwnedPCMBuffer(
                track: .system,
                presentationTimestampSeconds: mediaTime,
                format: systemFormat,
                frameCount: Self.systemFrames,
                samples: systemSamples
            ), elapsed: elapsed, boundary: boundary)
            systemIndex += 1

            // The microphone runs at its own smaller buffer size, so it is
            // caught up to the same media time rather than paced separately.
            while Double(microphoneIndex * Self.microphoneFrames) / Self.sampleRate < mediaTime {
                ingest(try OwnedPCMBuffer(
                    track: .microphone,
                    presentationTimestampSeconds: Double(microphoneIndex * Self.microphoneFrames) / Self.sampleRate,
                    format: microphoneFormat,
                    frameCount: Self.microphoneFrames,
                    samples: microphoneSamples
                ), elapsed: elapsed, boundary: boundary)
                microphoneIndex += 1
            }

            let second = Int(elapsed)
            if second != lastCallbackSecond {
                lastCallbackSecond = second
                atElapsed(elapsed)
            }
        }

        // Let the writer finish what capture already accepted, exactly as a stop
        // does: the recorder never discards audio it took responsibility for.
        writerQueue.sync {}
        try store.finish()
        _ = try store.commitCapture(state: .complete, completionStatus: .complete)
        return lock.withLock { state }
    }

    /// Everything the sample handler does: bound, enqueue, and hand off. No disk
    /// work on this path.
    private func ingest(_ buffer: OwnedPCMBuffer, elapsed: TimeInterval, boundary: TimeInterval) {
        let accepted: Bool = lock.withLock {
            guard queuedBytes + buffer.samples.count <= Self.maximumQueuedBytes else {
                state.gaps += 1
                state.gapsByMinute[Int(elapsed / 60), default: 0] += 1
                if elapsed < boundary { state.gapsBeforeBoundary += 1 } else { state.gapsAfterBoundary += 1 }
                return false
            }
            pending.append(buffer)
            queuedBytes += buffer.samples.count
            state.peakQueuedBytes = max(state.peakQueuedBytes, queuedBytes)
            state.deliveredBuffers += 1
            return true
        }
        guard accepted else { return }
        writerQueue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            let next: OwnedPCMBuffer? = lock.withLock {
                guard !pending.isEmpty else { return nil }
                let buffer = pending.removeFirst()
                queuedBytes -= buffer.samples.count
                return buffer
            }
            guard let next else { return }
            do {
                try store.append(next)
            } catch {
                lock.withLock { state.writeFailures.append(error.localizedDescription) }
            }
        }
    }

    private static func samples(frames: Int, channels: Int) -> Data {
        var values = [Float](repeating: 0, count: frames * channels)
        for index in values.indices { values[index] = sin(Float(index) * 0.01) * 0.25 }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
