import Foundation
import Processing

/// Builds a capture archive from a synthetic audio fixture, then reconstructs it
/// with ``TimelineBuilder`` so the result can be scored by `Tools/AudioMetrics`.
///
/// The archive is shaped like the measurements in `docs/feasibility/capture-timing.md`
/// rather than like an idealized recording: the system track arrives in 960-frame
/// buffers, the microphone in 512-frame buffers at its own native rate, both on one
/// host-uptime presentation clock, and the microphone starts late by a per-session
/// amount drawn from the ten measured offsets. If the builder assumed a zero offset,
/// a constant offset, or first-sample alignment, these sessions would expose it.
public enum FixtureSession {
    /// Presentation timestamps sit on a realistic host-uptime scale, not near zero,
    /// so any accidental float accumulation in the timeline shows up as error.
    public static let sessionOriginSeconds = 207_492.667875

    /// The ten microphone start offsets measured across ten real `SCStream` runs.
    public static let measuredMicrophoneOffsets: [Double] = [
        0.331000, 2.593544, 0.146836, 0.122686, 0.136441,
        0.195770, 0.125396, 0.127459, 0.125660, 0.131103,
    ]

    public struct GroundTruth: Sendable {
        public let caseID: String
        public let microphoneSampleRate: Int
        public let driftRatio: Double
        public let gapIntervals: [(start: Double, end: Double)]
        public let durationSeconds: Double
    }

    public struct Result: Sendable {
        public let caseID: String
        public let sessionDirectory: URL
        /// The track exactly as the pipeline produces it: session grid, leading
        /// silence and all.
        public let processedURL: URL
        /// The same audio with the preserved leading silence removed, so a
        /// correlation-based measurement has the fixture's own time base to compare
        /// against instead of having to find a lead of up to 2.6 seconds.
        public let alignedURL: URL
        public let expectedLeadingSilenceFrames: Int64
        public let microphoneOffsetSeconds: Double
        public let microphoneLeadingSilenceFrames: Int64
        public let processingDelayMilliseconds: Double
        public let injectedDriftPPM: Double
        public let measuredDriftPPM: Double
        public let driftCorrected: Bool
        public let reconstructedFrames: Int64
        public let sourceMicrophoneFrames: Int
        public let journaledGapSeconds: Double
        public let diagnostics: [String]
    }

    public static func readGroundTruth(fixtureDirectory: URL) throws -> GroundTruth {
        let url = fixtureDirectory.appendingPathComponent("ground-truth.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw HarnessError.message("\(url.path) is not a JSON object")
        }
        let microphone = object["microphone"] as? [String: Any] ?? [:]
        let gaps = (object["gapIntervals"] as? [[String: Any]] ?? []).compactMap { entry -> (Double, Double)? in
            guard let start = (entry["startSeconds"] as? NSNumber)?.doubleValue,
                  let end = (entry["endSeconds"] as? NSNumber)?.doubleValue else { return nil }
            return (start, end)
        }
        return GroundTruth(
            caseID: object["caseID"] as? String ?? fixtureDirectory.lastPathComponent,
            microphoneSampleRate: Int((microphone["sampleRate"] as? NSNumber)?.doubleValue ?? 48_000),
            driftRatio: (object["driftRatio"] as? NSNumber)?.doubleValue ?? 1,
            gapIntervals: gaps,
            durationSeconds: (object["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    /// Synthesizes a session, reconstructs the microphone track, and writes it as
    /// 32-bit float WAV at the processing rate.
    public static func run(
        fixtureDirectory: URL,
        workingDirectory: URL,
        offsetIndex: Int,
        options: TimelineBuilderOptions = TimelineBuilderOptions()
    ) throws -> Result {
        let truth = try readGroundTruth(fixtureDirectory: fixtureDirectory)
        let microphone = try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("microphone.wav"))
        let playback = try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("playback.wav"))
        let offset = measuredMicrophoneOffsets[abs(offsetIndex) % measuredMicrophoneOffsets.count]

        let sessionDirectory = workingDirectory.appendingPathComponent(truth.caseID, isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDirectory)
        let writer = try CaptureArchiveWriter(sessionDirectory: sessionDirectory)

        // System track: 48 kHz stereo float, 960-frame buffers, starting at the origin.
        let systemChannels = playback.channelCount >= 2 ? playback.channels : [playback.channels[0], playback.channels[0]]
        try writeTrack(
            writer: writer, track: "system", channels: systemChannels, sampleRate: playback.sampleRate,
            bufferFrames: 960, startSeconds: sessionOriginSeconds, driftRatio: 1, gaps: []
        )

        // Microphone track: its own native rate and buffer size, starting late.
        // When the fixture declares a clock mismatch, the archive is written with the
        // drifted number of samples and the journal keeps true time, which is exactly
        // the shape a drifting capture device produces.
        let injectedDrift = truth.driftRatio
        let microphoneChannels = injectedDrift == 1
            ? microphone.channels
            : compress(microphone.channels, byRatio: injectedDrift, sampleRate: microphone.sampleRate)
        try writeTrack(
            writer: writer, track: "microphone", channels: microphoneChannels, sampleRate: microphone.sampleRate,
            bufferFrames: 512, startSeconds: sessionOriginSeconds + offset, driftRatio: injectedDrift,
            gaps: truth.gapIntervals
        )
        try writer.finish()

        let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory, options: options)
        guard let track = builder.timeline.track(.microphone), let reader = try builder.makeReader(for: .microphone) else {
            throw HarnessError.message("the reconstructed session has no microphone track")
        }
        let reconstructed = try reader.readAll()
        let processedURL = workingDirectory.appendingPathComponent("\(truth.caseID)-reconstructed-microphone.wav")
        try WAVAudio(sampleRate: timelineSampleRate, channels: reconstructed).write(to: processedURL)

        let leading = track.leadingSilenceFrames
        let alignedURL = workingDirectory.appendingPathComponent("\(truth.caseID)-aligned-microphone.wav")
        let trimmed = reconstructed.map { Array($0.dropFirst(Int(min(leading, Int64($0.count))))) }
        try WAVAudio(sampleRate: timelineSampleRate, channels: trimmed).write(to: alignedURL)
        return Result(
            caseID: truth.caseID,
            sessionDirectory: sessionDirectory,
            processedURL: processedURL,
            alignedURL: alignedURL,
            // The offset the session was written with, in 48 kHz frames. The plan's
            // own number has to match this exactly: a track's first sample belongs
            // where its own timestamp puts it against the session origin.
            expectedLeadingSilenceFrames: Int64((offset * Double(timelineSampleRate)).rounded()),
            microphoneOffsetSeconds: offset,
            microphoneLeadingSilenceFrames: leading,
            // Reported from the frame count the plan actually produced, so the value
            // handed to audio-metrics is the delay the output really carries.
            processingDelayMilliseconds: Double(leading) * 1000 / Double(timelineSampleRate),
            injectedDriftPPM: (injectedDrift - 1) * 1_000_000,
            measuredDriftPPM: track.drift.partsPerMillion,
            driftCorrected: track.drift.corrected,
            reconstructedFrames: Int64(reconstructed.first?.count ?? 0),
            sourceMicrophoneFrames: microphone.frameCount,
            journaledGapSeconds: track.gaps.reduce(0) { $0 + $1.duration.seconds },
            diagnostics: (builder.timeline.diagnostics + track.diagnostics).map { "\($0.code): \($0.message)" }
        )
    }

    /// Writes one track as a sequence of fixed-size buffers, skipping the frames that
    /// fall inside a declared gap and letting the timestamp jump across it — which is
    /// what makes the gap journaled rather than silently concatenated.
    private static func writeTrack(
        writer: CaptureArchiveWriter,
        track: String,
        channels: [[Float]],
        sampleRate: Int,
        bufferFrames: Int,
        startSeconds: Double,
        driftRatio: Double,
        gaps: [(start: Double, end: Double)]
    ) throws {
        let format = CaptureArchiveWriter.ArchiveFormat(sampleRate: sampleRate, channelCount: channels.count)
        let total = channels.first?.count ?? 0
        var frame = 0
        while frame < total {
            let count = min(bufferFrames, total - frame)
            let contentSeconds = Double(frame) / Double(sampleRate)
            // A gap removes the samples from the archive entirely; the journal records
            // the interval, and the builder is what puts the silence back.
            if let gap = gaps.first(where: { $0.start <= contentSeconds && contentSeconds < $0.end }) {
                frame = min(total, Int((gap.end * Double(sampleRate)).rounded()))
                continue
            }
            let timestamp = startSeconds + contentSeconds * driftRatio
            let slice = channels.map { Array($0[frame..<(frame + count)]) }
            try writer.write(CaptureArchiveWriter.BufferSpec(track: track, timestampSeconds: timestamp, channels: slice, format: format))
            frame += count
        }
    }

    /// Squeezes a signal by `ratio` so that stretching it back by the same ratio — the
    /// correction the builder derives from the journal — restores the original.
    private static func compress(_ channels: [[Float]], byRatio ratio: Double, sampleRate: Int) -> [[Float]] {
        let resampler = SincResampler(
            inputSampleRate: sampleRate,
            outputSampleRate: sampleRate,
            driftRatio: 1 / ratio,
            channelCount: channels.count
        )
        return resampler.process(channels, isFinal: true)
    }
}
