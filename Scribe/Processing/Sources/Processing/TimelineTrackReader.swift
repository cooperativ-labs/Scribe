import Foundation
import ScribeAppCore

/// A block of reconstructed audio on the 48 kHz session grid.
public struct ReconstructedBlock: Sendable, Equatable {
    /// Frames from the session origin.
    public let startFrame: Int64
    /// Deinterleaved float channels in -1...1.
    public let channels: [[Float]]
    /// True when every sample in this block is inserted silence rather than capture.
    public let isSilence: Bool

    public var frameCount: Int { channels.first?.count ?? 0 }
}

/// Streams one reconstructed track in bounded blocks.
///
/// Working buffers are float PCM; the CAF archive keeps its native integer or
/// float layout and is only ever read. Memory stays bounded by the block size plus
/// the resampler's kernel context, so a two-hour session costs no more than a short
/// one.
public final class TimelineTrackReader {
    public let track: RecorderTrackKind
    public let channelCount: Int
    public let frameCount: Int64
    public let timeline: TrackTimeline

    /// The default pull size: one 10 ms processing block at 48 kHz.
    public static let defaultBlockFrames = timelineSampleRate / 100

    private enum Span {
        case silence(frames: Int64)
        case run(index: Int, frames: Int64)
    }

    private let captureDirectory: URL
    private let options: TimelineBuilderOptions
    private var spans: [Span]
    private var spanIndex = 0
    private var framesEmittedInSpan: Int64 = 0
    private var outputCursor: Int64 = 0

    private var currentResampler: SincResampler?
    private var currentExtentIndex = 0
    private var currentExtentFrameOffset: Int64 = 0
    private var currentReader: CAFSegmentReader?
    private var currentReaderFile: String?
    private var pendingOutput: [[Float]] = []

    init(trackTimeline: TrackTimeline, captureDirectory: URL, options: TimelineBuilderOptions) throws {
        self.track = trackTimeline.track
        self.timeline = trackTimeline
        self.channelCount = trackTimeline.channelCount
        self.frameCount = trackTimeline.outputFrameCount
        self.captureDirectory = captureDirectory
        self.options = options

        // Silence exists only where the plan puts it: before a track's first sample,
        // and across a journaled gap. Runs are never concatenated to close one.
        var spans: [Span] = []
        var cursor: Int64 = 0
        for (index, run) in trackTimeline.runs.enumerated() {
            if run.outputStartFrame > cursor {
                spans.append(.silence(frames: run.outputStartFrame - cursor))
                cursor = run.outputStartFrame
            }
            spans.append(.run(index: index, frames: run.outputFrameCount))
            cursor += run.outputFrameCount
        }
        self.spans = spans
    }

    deinit { try? currentReader?.close() }

    /// Returns the next block, or nil at the end of the track.
    public func read(maxFrames: Int = TimelineTrackReader.defaultBlockFrames) throws -> ReconstructedBlock? {
        precondition(maxFrames > 0)
        while spanIndex < spans.count {
            switch spans[spanIndex] {
            case .silence(let frames):
                let remaining = frames - framesEmittedInSpan
                if remaining <= 0 { advanceSpan(); continue }
                let count = Int(min(Int64(maxFrames), remaining))
                let block = ReconstructedBlock(
                    startFrame: outputCursor,
                    channels: Array(repeating: [Float](repeating: 0, count: count), count: channelCount),
                    isSilence: true
                )
                framesEmittedInSpan += Int64(count)
                outputCursor += Int64(count)
                if framesEmittedInSpan >= frames { advanceSpan() }
                return block

            case let .run(index, frames):
                let remaining = frames - framesEmittedInSpan
                if remaining <= 0 { closeRun(); advanceSpan(); continue }
                let want = Int(min(Int64(maxFrames), remaining))
                let produced = try produce(runIndex: index, frames: want)
                guard !produced.isEmpty, produced[0].count > 0 else { closeRun(); advanceSpan(); continue }
                let block = ReconstructedBlock(startFrame: outputCursor, channels: produced, isSilence: false)
                framesEmittedInSpan += Int64(produced[0].count)
                outputCursor += Int64(produced[0].count)
                if framesEmittedInSpan >= frames { closeRun(); advanceSpan() }
                return block
            }
        }
        return nil
    }

    /// Convenience for callers that want the whole track at once. Streaming through
    /// ``read(maxFrames:)`` is the production path; this exists for tests, fixture
    /// measurement, and short sessions.
    public func readAll() throws -> [[Float]] {
        var channels = Array(repeating: [Float](), count: channelCount)
        while let block = try read(maxFrames: TimelineTrackReader.defaultBlockFrames * 100) {
            for channel in 0..<channelCount { channels[channel].append(contentsOf: block.channels[channel]) }
        }
        return channels
    }

    private func advanceSpan() {
        spanIndex += 1
        framesEmittedInSpan = 0
    }

    private func closeRun() {
        currentResampler = nil
        currentExtentIndex = 0
        currentExtentFrameOffset = 0
        pendingOutput = []
        try? currentReader?.close()
        currentReader = nil
        currentReaderFile = nil
    }

    private func produce(runIndex: Int, frames wanted: Int) throws -> [[Float]] {
        let run = timeline.runs[runIndex]
        if currentResampler == nil {
            currentResampler = SincResampler(
                inputSampleRate: run.format.sampleRate,
                outputSampleRate: timelineSampleRate,
                driftRatio: timeline.drift.appliedRatio,
                channelCount: run.format.channelCount,
                contextFrames: options.resamplerContextFrames
            )
            pendingOutput = Array(repeating: [], count: run.format.channelCount)
        }
        guard let resampler = currentResampler else { return [] }

        // The resampler needs enough input context around the positions it is asked
        // for, so pull native frames until the output is available or the run ends.
        let nativePerOutput = resampler.step
        while (pendingOutput.first?.count ?? 0) < wanted {
            let need = max(TimelineTrackReader.defaultBlockFrames, Int((Double(wanted) * nativePerOutput).rounded(.up)) + resampler.contextFrames * 2)
            let (input, isFinal) = try readNative(run: run, frames: need)
            if input.first?.isEmpty ?? true, !isFinal { break }
            let produced = resampler.process(input, isFinal: isFinal)
            for channel in 0..<produced.count { pendingOutput[channel].append(contentsOf: produced[channel]) }
            if isFinal { break }
        }

        let available = min(wanted, pendingOutput.first?.count ?? 0)
        guard available > 0 else { return [] }
        var output = Array(repeating: [Float](), count: run.format.channelCount)
        for channel in 0..<run.format.channelCount {
            output[channel] = Array(pendingOutput[channel].prefix(available))
            pendingOutput[channel].removeFirst(available)
        }
        return widen(output)
    }

    /// Widens a run that carries fewer channels than the track's canonical layout by
    /// repeating its last channel, which keeps a mid-session channel-count change
    /// audible on every output channel instead of dropping to silence.
    private func widen(_ channels: [[Float]]) -> [[Float]] {
        guard channels.count < channelCount, let last = channels.last else { return channels }
        return channels + Array(repeating: last, count: channelCount - channels.count)
    }

    /// Pulls up to `frames` native frames from the run's extents, and reports whether
    /// that exhausted the run.
    private func readNative(run: TimelineRun, frames: Int) throws -> ([[Float]], Bool) {
        var channels = Array(repeating: [Float](), count: run.format.channelCount)
        var remaining = frames

        while remaining > 0, currentExtentIndex < run.extents.count {
            let extent = run.extents[currentExtentIndex]
            if currentReaderFile != extent.file {
                try? currentReader?.close()
                let url = captureDirectory.appendingPathComponent(extent.file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TimelineBuilderError.missingSegment(extent.file)
                }
                currentReader = try CAFSegmentReader(url: url)
                currentReaderFile = extent.file
            }
            guard let reader = currentReader else { break }
            let left = extent.frameCount - currentExtentFrameOffset
            if left <= 0 {
                currentExtentIndex += 1
                currentExtentFrameOffset = 0
                continue
            }
            let count = Int(min(Int64(remaining), left))
            let read = try reader.readFrames(startingAt: extent.fileFrameOffset + currentExtentFrameOffset, count: count)
            let got = read.first?.count ?? 0
            guard got > 0 else {
                // The segment is shorter than the journal claims — a crash mid-write.
                // Treat the run as ending here rather than fabricating samples.
                currentExtentIndex = run.extents.count
                break
            }
            for channel in 0..<min(channels.count, read.count) { channels[channel].append(contentsOf: read[channel]) }
            currentExtentFrameOffset += Int64(got)
            remaining -= got
        }

        let exhausted = currentExtentIndex >= run.extents.count
            || (currentExtentIndex == run.extents.count - 1 && currentExtentFrameOffset >= run.extents[currentExtentIndex].frameCount)
        return (channels, exhausted)
    }
}
