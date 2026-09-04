import AVFAudio
import FLACBridge
import Foundation
import ScribeAppCore
import WebRTCBridge

/// Produces `final.flac`: the original system signal mixed with the echo-cancelled
/// microphone, 48 kHz stereo 24-bit.
///
/// The shape of the job follows section 5 directly. Both tracks are already on one
/// 48 kHz grid from ``TimelineBuilder``, so block *i* of each is simultaneous by
/// construction and the only remaining unknown is the acoustic delay, which
/// ``RenderDelayEstimator`` measures from the session's own audio. Three passes
/// keep it streaming and memory-bounded at any session length:
///
/// 1. estimate the render-to-capture delay across the whole session;
/// 2. cancel and mix into a scratch file while metering true peak;
/// 3. apply one static gain for the −1 dBTP ceiling and encode.
///
/// The ceiling is a single static gain rather than a compressor because section 5
/// asks for peak control and explicitly not for loudness processing: a linear gain
/// changes no relative level anywhere in the meeting and is exactly invertible.
///
/// Failure is a first-class outcome. A job that cannot establish a delay while
/// evidently having an echo to cancel does not publish anything: the originals
/// stay exactly as they were, any previously valid `final.flac` is left alone, and
/// the manifest records `failed` with the reason.
public struct MixdownService: Sendable {
    public static let journalReference = "capture/timeline.jsonl"
    public static let outputFileName = "final.flac"

    public struct Options: Sendable, Equatable {
        /// Conservative fixed gains, per section 5. Both tracks are attenuated by
        /// the same 3 dB so neither is favoured before the mix, and the microphone
        /// is centred by taking that same amplitude to both channels.
        public var systemGain: Float
        public var microphoneGain: Float
        /// Section 5's proposed ceiling.
        public var truePeakCeilingDbTP: Double
        public var echoCanceller: EchoCanceller.Configuration
        public var delayEstimator: RenderDelayEstimator.Options

        public init(
            systemGain: Float = 0.708_0,
            microphoneGain: Float = 0.708_0,
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

        var truePeakCeilingLinear: Double { pow(10, truePeakCeilingDbTP / 20) }
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

        // Pass 2 — cancel and mix to a scratch file, metering true peak.
        var systemReader = try blockReader(builder, .system, frames: totalFrames, blockFrames: blockFrames)
        var microphoneReader = try blockReader(builder, .microphone, frames: totalFrames, blockFrames: blockFrames)
        let scratchURL = sessionDirectory.appendingPathComponent(".final.mix.\(UUID().uuidString).f32")
        FileManager.default.createFile(atPath: scratchURL.path, contents: nil)
        guard let scratch = try? FileHandle(forWritingTo: scratchURL) else {
            throw MixdownError.scratchUnavailable(scratchURL.path)
        }
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        var meter = TruePeakMeter(channelCount: 2)
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
                meter.append(mixed)
                for channel in mixed { for sample in channel { samplePeak = max(samplePeak, abs(sample)) } }
                try scratch.write(contentsOf: Self.interleavedData(mixed))
                writtenFrames += Int64(mixed[0].count)
            }
        }

        while let system = systemReader.next(), let microphone = microphoneReader.next() {
            if pendingSystem.count < system.count { pendingSystem = Array(repeating: [], count: system.count) }
            for channel in 0..<system.count { pendingSystem[channel].append(contentsOf: system[channel]) }
            try emit(try canceller.process(reference: system, microphone: Self.mono(microphone)))
        }
        try emit(try canceller.finish(expectedFrameCount: totalFrames))
        try scratch.close()
        meter.finish()

        guard writtenFrames == totalFrames else {
            throw MixdownError.durationMismatch(expectedFrames: totalFrames, actualFrames: writtenFrames)
        }

        // Pass 3 — one static gain, then encode.
        let ceiling = options.truePeakCeilingLinear
        let truePeak = meter.truePeak
        let peakGain = truePeak > ceiling ? Float(ceiling / truePeak) : 1
        let encoder = try FLACEncoder(
            outputURL: sessionDirectory.appendingPathComponent(Self.outputFileName),
            configuration: FLACEncoderConfiguration(sampleRate: timelineSampleRate, channelCount: 2, bitDepth: .bits24)
        )
        do {
            try encode(scratchURL: scratchURL, gain: peakGain, blockFrames: blockFrames, into: encoder)
        } catch {
            encoder.cancel()
            throw error
        }
        let encoded = try encoder.finish()
        guard encoded.frameCount == totalFrames else {
            throw MixdownError.durationMismatch(expectedFrames: totalFrames, actualFrames: encoded.frameCount)
        }

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

    private func encode(scratchURL: URL, gain: Float, blockFrames: Int, into encoder: FLACEncoder) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(timelineSampleRate), channels: 2, interleaved: false) else {
            throw MixdownError.invalidOutputFormat
        }
        let handle = try FileHandle(forReadingFrom: scratchURL)
        defer { try? handle.close() }
        let bytesPerFrame = MemoryLayout<Float>.size * 2

        while true {
            guard let data = try handle.read(upToCount: blockFrames * bytesPerFrame), !data.isEmpty else { break }
            let frames = data.count / bytesPerFrame
            guard frames > 0 else { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                throw MixdownError.bufferAllocationFailed
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: Float.self)
                for frame in 0..<frames {
                    // The gain is at most 1, so this can only ever move a sample
                    // towards zero; the clamp is a floor under arithmetic, not a
                    // limiter doing shaping of its own.
                    buffer.floatChannelData![0][frame] = min(1, max(-1, source[frame * 2] * gain))
                    buffer.floatChannelData![1][frame] = min(1, max(-1, source[frame * 2 + 1] * gain))
                }
            }
            try encoder.write(buffer)
        }
    }

    // MARK: - Mixing

    /// Mixes one block: the *original* system signal, untouched by the canceller,
    /// with the cleaned microphone placed at the centre of the stereo image.
    static func mixBlock(system: [[Float]], microphone: [Float], options: Options) -> [[Float]] {
        let frames = min(system.first?.count ?? 0, microphone.count)
        let left = system.first ?? []
        let right = system.count > 1 ? system[1] : left
        var outputLeft = [Float](repeating: 0, count: frames)
        var outputRight = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            let centred = microphone[frame] * options.microphoneGain
            outputLeft[frame] = left[frame] * options.systemGain + centred
            outputRight[frame] = right[frame] * options.systemGain + centred
        }
        return [outputLeft, outputRight]
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

    static func interleavedData(_ channels: [[Float]]) -> Data {
        let frames = channels.first?.count ?? 0
        var samples = [Float](repeating: 0, count: frames * channels.count)
        for (index, channel) in channels.enumerated() {
            for frame in 0..<frames { samples[frame * channels.count + index] = channel[frame] }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
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
    case scratchUnavailable(String)
    case invalidOutputFormat
    case bufferAllocationFailed
    case durationMismatch(expectedFrames: Int64, actualFrames: Int64)

    public var code: String {
        switch self {
        case .missingTrack: return "mixdown.missing-track"
        case .emptyTimeline: return "mixdown.empty-timeline"
        case .uncertainDelay: return "mixdown.uncertain-delay"
        case .scratchUnavailable: return "mixdown.scratch-unavailable"
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
        case .scratchUnavailable(let path): return "could not open the mix scratch file at \(path)"
        case .invalidOutputFormat: return "cannot create the 48 kHz stereo mix format"
        case .bufferAllocationFailed: return "could not allocate the mix output buffer"
        case let .durationMismatch(expected, actual): return "the mix has \(actual) frames; the reconstructed timeline is \(expected)"
        }
    }
}
