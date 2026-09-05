import AVFAudio
import FLACBridge
import Foundation
import ScribeAppCore
import WebRTCBridge

/// Produces `final.flac`: the original system signal mixed with the echo-cancelled
/// microphone, 48 kHz mono 16-bit for transcription.
///
/// Both tracks are already on one 48 kHz grid from ``TimelineBuilder``, so block
/// *i* of each is simultaneous by construction and the only remaining unknown is
/// the acoustic delay, which ``RenderDelayEstimator`` measures from the session's
/// own audio. Two streaming passes keep work bounded at any session length:
///
/// 1. estimate the render-to-capture delay across the whole session;
/// 2. cancel, mix with conservative fixed gains, and encode directly to FLAC.
///
/// Failure is a first-class outcome. A job that cannot establish a delay while
/// evidently having an echo to cancel does not publish anything: the originals
/// stay exactly as they were, any previously valid `final.flac` is left alone, and
/// the manifest records `failed` with the reason.
public struct MixdownService: Sendable {
    public static let journalReference = "capture/timeline.jsonl"
    public static let outputFileName = "final.flac"

    public struct Options: Sendable, Equatable {
        /// Conservative fixed gains. At 0.44 each, two full-scale sources sum to
        /// 0.88 (about −1.1 dBFS), so transcription audio can be streamed directly
        /// without a scratch-file peak-normalization pass.
        public var systemGain: Float
        public var microphoneGain: Float
        /// Section 5's proposed ceiling.
        public var truePeakCeilingDbTP: Double
        public var echoCanceller: EchoCanceller.Configuration
        public var delayEstimator: RenderDelayEstimator.Options

        public init(
            systemGain: Float = 0.44,
            microphoneGain: Float = 0.44,
            truePeakCeilingDbTP: Double = -1,
            echoCanceller: EchoCanceller.Configuration = EchoCanceller.Configuration(),
            delayEstimator: RenderDelayEstimator.Options = RenderDelayEstimator.Options()
        ) {
            self.systemGain = systemGain
            self.microphoneGain = microphoneGain
            self.truePeakCeilingDbTP = truePeakCeilingDbTP
            self.echoCanceller = echoCanceller
            self.delayEstimator = delayEstimator
        }
    }

    public init() {}

    /// Runs the whole job for a session directory and atomically records the
    /// outcome in `metadata.json`.
    ///
    /// `cleanedMicrophone` receives the echo-cancelled microphone in order, before
    /// any mix gain. Section 8 states the local-speech gate "before mix gain", so
    /// that signal has to be observable without re-deriving it from the mix.
    @discardableResult
    public func run(
        sessionDirectory: URL,
        options: Options = Options(),
        cleanedMicrophone: (([Float]) -> Void)? = nil
    ) throws -> MixdownResult {
        let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory)
        let manifestURL = sessionDirectory.appendingPathComponent("metadata.json")
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))
        do {
            let result = try mix(builder: builder, sessionDirectory: sessionDirectory, manifest: manifest, options: options, cleanedMicrophone: cleanedMicrophone)
            try AtomicReplaceFileWriter().write(result.manifest, to: manifestURL)
            return result
        } catch let error as MixdownError {
            // Report the failure into the manifest without disturbing anything the
            // session already holds: originals, unprocessed exports, and any
            // previously published final file are all left exactly as they were.
            let failed = failureManifest(manifest, timeline: builder.timeline, options: options, error: error)
            try? AtomicReplaceFileWriter().write(failed, to: manifestURL)
            throw error
        }
    }

    /// Runs only the delay-estimation pass and returns what it found.
    ///
    /// The mixdown does this itself; this seam exists so a tool or a failed job
    /// can report *why* an echo path was or was not established without having to
    /// re-derive it from the audio.
    public func estimateEchoPath(sessionDirectory: URL, options: Options = Options()) throws -> RenderDelayPlan {
        let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory)
        return try estimateEchoPath(builder: builder, options: options)
    }

    private func estimateEchoPath(builder: TimelineBuilder, options: Options) throws -> RenderDelayPlan {
        let totalFrames = builder.timeline.outputFrameCount
        guard totalFrames > 0 else { throw MixdownError.emptyTimeline }
        var system = try blockReader(builder, .system, frames: totalFrames, blockFrames: options.echoCanceller.blockFrames)
        var microphone = try blockReader(builder, .microphone, frames: totalFrames, blockFrames: options.echoCanceller.blockFrames)
        return RenderDelayEstimator(options: options.delayEstimator, expectedFrameCount: totalFrames)
            .plan {
                guard let reference = system.next(), let capture = microphone.next() else { return nil }
                return (reference: Self.mono(reference), microphone: Self.mono(capture))
            }
    }

    // MARK: - The job

    private func mix(
        builder: TimelineBuilder,
        sessionDirectory: URL,
        manifest: RecorderSessionManifest,
        options: Options,
        cleanedMicrophone: (([Float]) -> Void)?
    ) throws -> MixdownResult {
        guard builder.timeline.track(.system) != nil else { throw MixdownError.missingTrack(.system) }
        guard let microphoneTrack = builder.timeline.track(.microphone) else { throw MixdownError.missingTrack(.microphone) }
        let blockFrames = options.echoCanceller.blockFrames
        let totalFrames = builder.timeline.outputFrameCount
        guard totalFrames > 0 else { throw MixdownError.emptyTimeline }

        // Pass 1 — where is the echo?
        let plan = try estimateEchoPath(builder: builder, options: options)
        if case .uncertain(let reason, _, _) = plan.decision {
            throw MixdownError.uncertainDelay(reason: reason)
        }

        // Reconvergence: everything the journal says changed the echo path, plus
        // every output-route change the recorder observed. A route change leaves
        // the timeline continuous and still replaces the speaker at the other end
        // of the path, which is precisely the case an adapted filter gets wrong.
        let reconvergences = reconvergenceFrames(timeline: builder.timeline, manifest: manifest)
        let canceller = try EchoCanceller(
            configuration: options.echoCanceller,
            plan: plan,
            reconvergenceFrames: reconvergences,
            outputFrameCount: totalFrames
        )

        // Pass 2 — cancel, mix, and encode directly. The conservative fixed gains
        // make the former scratch-file true-peak pass unnecessary for speech.
        var systemReader = try blockReader(builder, .system, frames: totalFrames, blockFrames: blockFrames)
        var microphoneReader = try blockReader(builder, .microphone, frames: totalFrames, blockFrames: blockFrames)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(timelineSampleRate),
            channels: 1,
            interleaved: false
        ) else { throw MixdownError.invalidOutputFormat }
        let encoder = try FLACEncoder(
            outputURL: sessionDirectory.appendingPathComponent(Self.outputFileName),
            configuration: FLACEncoderConfiguration(sampleRate: timelineSampleRate, channelCount: 1, bitDepth: .bits16)
        )
        // The system side is held as a flat sample queue rather than a queue of
        // blocks. The canceller's output blocks do not have to line up one-for-one
        // with its input blocks — a measured DSP latency shifts them, and the final
        // block is partial — and a queue indexed by samples cannot drift out of
        // step with them the way a queue indexed by blocks could.
        var pendingSystem: [[Float]] = []
        var writtenFrames: Int64 = 0
        var samplePeak: Float = 0

        func emit(_ cleaned: [[Float]]) throws {
            for block in cleaned where !block.isEmpty {
                cleanedMicrophone?(block)
                let system = Self.take(block.count, from: &pendingSystem)
                let mixed = Self.mixBlock(system: system, microphone: block, options: options)
                for channel in mixed { for sample in channel { samplePeak = max(samplePeak, abs(sample)) } }
                try write(mixed, format: outputFormat, into: encoder)
                writtenFrames += Int64(mixed[0].count)
            }
        }

        do {
            while let system = systemReader.next(), let microphone = microphoneReader.next() {
                if pendingSystem.count < system.count { pendingSystem = Array(repeating: [], count: system.count) }
                for channel in 0..<system.count { pendingSystem[channel].append(contentsOf: system[channel]) }
                try emit(try canceller.process(reference: system, microphone: Self.mono(microphone)))
            }
            try emit(try canceller.finish(expectedFrameCount: totalFrames))
        } catch {
            encoder.cancel()
            throw error
        }

        guard writtenFrames == totalFrames else {
            encoder.cancel()
            throw MixdownError.durationMismatch(expectedFrames: totalFrames, actualFrames: writtenFrames)
        }

        let encoded = try encoder.finish()
        guard encoded.frameCount == totalFrames else {
            throw MixdownError.durationMismatch(expectedFrames: totalFrames, actualFrames: encoded.frameCount)
        }
        let peakGain: Float = 1
        let truePeak = Double(samplePeak)

        let summary = MixdownSummary(
            decision: plan.decision,
            delayPlan: plan,
            reconvergences: canceller.reconvergences,
            processingLatencyFrames: canceller.processingLatencyFrames,
            metrics: canceller.metrics(),
            systemGain: options.systemGain,
            microphoneGain: options.microphoneGain,
            truePeakBeforeGain: truePeak,
            samplePeakBeforeGain: Double(samplePeak),
            appliedPeakGain: Double(peakGain),
            truePeakCeilingDbTP: options.truePeakCeilingDbTP,
            microphoneOutputFrameCount: microphoneTrack.outputFrameCount
        )
        return MixdownResult(
            timeline: builder.timeline,
            summary: summary,
            result: encoded,
            manifest: successManifest(manifest, timeline: builder.timeline, summary: summary, encoded: encoded, options: options)
        )
    }

    private func write(_ channels: [[Float]], format: AVAudioFormat, into encoder: FLACEncoder) throws {
        guard let samples = channels.first, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MixdownError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].initialize(from: source.baseAddress!, count: samples.count)
        }
        try encoder.write(buffer)
    }

    // MARK: - Mixing

    /// Mixes one block: the *original* system signal, untouched by the canceller,
    /// with the cleaned microphone into a mono transcription stream.
    static func mixBlock(system: [[Float]], microphone: [Float], options: Options) -> [[Float]] {
        let frames = min(system.first?.count ?? 0, microphone.count)
        let systemMono = mono(system)
        var output = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            output[frame] = systemMono[frame] * options.systemGain + microphone[frame] * options.microphoneGain
        }
        return [output]
    }

    /// Pops `frames` from the front of a per-channel sample queue, zero-filling if
    /// the queue has run dry — which happens only past the end of the timeline.
    static func take(_ frames: Int, from queue: inout [[Float]]) -> [[Float]] {
        guard !queue.isEmpty else { return [[Float](repeating: 0, count: frames)] }
        return (0..<queue.count).map { channel in
            var samples = Array(queue[channel].prefix(frames))
            queue[channel].removeFirst(samples.count)
            if samples.count < frames { samples.append(contentsOf: [Float](repeating: 0, count: frames - samples.count)) }
            return samples
        }
    }

    static func mono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        var output = first
        for channel in channels.dropFirst() {
            for index in 0..<min(output.count, channel.count) { output[index] += channel[index] }
        }
        let scale = 1 / Float(channels.count)
        for index in 0..<output.count { output[index] *= scale }
        return output
    }

    // MARK: - Inputs

    private func blockReader(_ builder: TimelineBuilder, _ track: RecorderTrackKind, frames: Int64, blockFrames: Int) throws -> FixedBlockReader {
        guard let reader = try builder.makeReader(for: track) else { throw MixdownError.missingTrack(track) }
        let channelCount = builder.timeline.track(track)?.channelCount ?? 1
        return FixedBlockReader(reader: reader, channelCount: channelCount, totalFrames: frames, blockFrames: blockFrames)
    }

    /// Where the adapted filter must be discarded, in 48 kHz frames.
    private func reconvergenceFrames(timeline: SessionTimeline, manifest: RecorderSessionManifest) -> [(frame: Int64, reason: String)] {
        var points: [Int64: String] = [:]
        for track in timeline.tracks {
            // A run boundary is recorded first because a journaled gap produces
            // one at the same frame, and the gap is the more specific account of
            // why the echo path may have moved.
            for run in track.runs.dropFirst() {
                points[run.outputStartFrame] = "\(track.track.rawValue) run boundary"
            }
            for gap in track.gaps {
                points[gap.outputStartFrame + gap.outputFrameCount] = "\(track.track.rawValue) gap ended (\(gap.reason))"
            }
        }
        // Route changes carry wall-clock dates, and the session grid is measured
        // from the recorder's own media clock, so they are mapped through the
        // session start. That is the only correspondence the manifest records; it
        // is good to the buffer, which is the resolution a reconvergence needs.
        for change in manifest.capture.outputDeviceChanges {
            let seconds = change.occurredAt.timeIntervalSince(manifest.startedAt)
            guard seconds > 0, seconds < timeline.durationSeconds else { continue }
            let frame = Int64((seconds * Double(timelineSampleRate)).rounded())
            points[frame] = "output route changed to \(change.currentDevice.name)"
        }
        return points.keys.sorted().map { (frame: $0, reason: points[$0] ?? "journaled discontinuity") }
    }

    /// Pulls a track in exactly `blockFrames` blocks, padding the tail with silence
    /// so both tracks run the full session length even when one ends early.
    struct FixedBlockReader {
        private let reader: TimelineTrackReader
        private let channelCount: Int
        private let totalFrames: Int64
        private let blockFrames: Int
        private var buffer: [[Float]]
        private var emitted: Int64 = 0
        private var exhausted = false

        init(reader: TimelineTrackReader, channelCount: Int, totalFrames: Int64, blockFrames: Int) {
            self.reader = reader
            self.channelCount = max(1, channelCount)
            self.totalFrames = totalFrames
            self.blockFrames = blockFrames
            self.buffer = Array(repeating: [], count: max(1, channelCount))
        }

        mutating func next() -> [[Float]]? {
            guard emitted < totalFrames else { return nil }
            while (buffer.first?.count ?? 0) < blockFrames, !exhausted {
                if let block = (try? reader.read(maxFrames: blockFrames)) ?? nil {
                    for channel in 0..<channelCount {
                        buffer[channel].append(contentsOf: channel < block.channels.count ? block.channels[channel] : block.channels[block.channels.count - 1])
                    }
                } else {
                    exhausted = true
                }
            }
            let wanted = Int(min(Int64(blockFrames), totalFrames - emitted))
            var output = Array(repeating: [Float](repeating: 0, count: wanted), count: channelCount)
            for channel in 0..<channelCount {
                let available = min(wanted, buffer[channel].count)
                if available > 0 {
                    output[channel].replaceSubrange(0..<available, with: buffer[channel].prefix(available))
                    buffer[channel].removeFirst(available)
                }
            }
            emitted += Int64(wanted)
            return output
        }
    }
}

/// What the mixdown decided and measured, for the manifest and for a reviewer.
public struct MixdownSummary: Sendable, Equatable {
    public let decision: EchoPathDecision
    public let delayPlan: RenderDelayPlan
    public let reconvergences: [EchoCanceller.Reconvergence]
    public let processingLatencyFrames: Int
    public let metrics: EchoCancellerMetrics
    public let systemGain: Float
    public let microphoneGain: Float
    public let truePeakBeforeGain: Double
    public let samplePeakBeforeGain: Double
    public let appliedPeakGain: Double
    public let truePeakCeilingDbTP: Double
    public let microphoneOutputFrameCount: Int64

    public var processingLatencySeconds: Double { Double(processingLatencyFrames) / Double(timelineSampleRate) }
}

public struct MixdownResult: Sendable, Equatable {
    public let timeline: SessionTimeline
    public let summary: MixdownSummary
    public let result: FLACEncodeResult
    public let manifest: RecorderSessionManifest
}

public enum MixdownError: Error, Equatable, CustomStringConvertible {
    case missingTrack(RecorderTrackKind)
    case emptyTimeline
    case uncertainDelay(reason: String)
    case invalidOutputFormat
    case bufferAllocationFailed
    case durationMismatch(expectedFrames: Int64, actualFrames: Int64)

    public var code: String {
        switch self {
        case .missingTrack: return "mixdown.missing-track"
        case .emptyTimeline: return "mixdown.empty-timeline"
        case .uncertainDelay: return "mixdown.uncertain-delay"
        case .invalidOutputFormat: return "mixdown.invalid-output-format"
        case .bufferAllocationFailed: return "mixdown.buffer-allocation-failed"
        case .durationMismatch: return "mixdown.duration-mismatch"
        }
    }

    public var description: String {
        switch self {
        case .missingTrack(let track): return "the session has no \(track.rawValue) track to mix"
        case .emptyTimeline: return "the reconstructed timeline is empty"
        case .uncertainDelay(let reason): return "echo cancellation was not attempted: \(reason)"
        case .invalidOutputFormat: return "cannot create the 48 kHz stereo mix format"
        case .bufferAllocationFailed: return "could not allocate the mix output buffer"
        case let .durationMismatch(expected, actual): return "the mix has \(actual) frames; the reconstructed timeline is \(expected)"
        }
    }
}
