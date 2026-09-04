import Foundation
import ScribeAppCore

/// Reconstructs a recorded session's tracks on one 48 kHz timeline.
///
/// The builder reads `capture/timeline.jsonl` and the CAF segments beside it and
/// produces a ``SessionTimeline``: one session origin, each track placed at its own
/// measured first timestamp, journaled gaps represented as silence, and drift
/// corrected on the processing copy. It opens the archive read-only and writes
/// nothing back into `capture/`.
///
/// Planning is separate from reading. ``plan(sessionDirectory:options:)`` decides
/// the whole layout from the journal alone — cheap, testable, and enough to record
/// in the manifest — while ``makeReader(for:)`` streams the audio in bounded blocks.
public struct TimelineBuilder: Sendable {
    public let sessionDirectory: URL
    public let captureDirectory: URL
    public let timeline: SessionTimeline
    private let options: TimelineBuilderOptions

    public static func plan(sessionDirectory: URL, options: TimelineBuilderOptions = TimelineBuilderOptions()) throws -> TimelineBuilder {
        let captureDirectory = sessionDirectory.appendingPathComponent("capture", isDirectory: true)
        let journalURL = captureDirectory.appendingPathComponent("timeline.jsonl")
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw TimelineBuilderError.missingJournal(journalURL.path)
        }
        let journal = try CaptureJournal.read(contentsOf: journalURL)
        let timeline = try build(journal: journal, captureDirectory: captureDirectory, options: options)
        return TimelineBuilder(sessionDirectory: sessionDirectory, captureDirectory: captureDirectory, timeline: timeline, options: options)
    }

    /// A bounded, streaming reader for one reconstructed track.
    public func makeReader(for track: RecorderTrackKind) throws -> TimelineTrackReader? {
        guard let trackTimeline = timeline.track(track) else { return nil }
        return try TimelineTrackReader(
            trackTimeline: trackTimeline,
            captureDirectory: captureDirectory,
            options: options
        )
    }

    // MARK: - Planning

    /// One journaled buffer: where it starts in time, and where its samples live.
    private struct JournaledBuffer {
        let timestamp: RationalTime
        let file: String
        let fileFrameOffset: Int64
        /// A journaled discontinuity immediately before this buffer.
        var precedingGap: RationalTime?
        var precedingOverlap: RationalTime?
        var frameCount: Int64 = 0
    }

    static func build(journal: CaptureJournal, captureDirectory: URL, options: TimelineBuilderOptions) throws -> SessionTimeline {
        var buffers: [RecorderTrackKind: [JournaledBuffer]] = [:]
        var segmentFrameCounts: [String: Int64] = [:]
        var segmentFormats: [String: CaptureAudioFormat] = [:]
        var firstTimestamps: [RecorderTrackKind: RationalTime] = [:]
        var sessionDiagnostics: [TimelineDiagnostic] = []

        for record in journal.records {
            switch record {
            case let .initialTimestamp(track, timestamp, file, _, format):
                if firstTimestamps[track] == nil { firstTimestamps[track] = timestamp }
                if let format { segmentFormats[file] = format }
            case let .segmentOpened(_, file, format):
                if let format { segmentFormats[file] = format }
            case let .segmentClosed(_, file, _, frameCount, _):
                segmentFrameCounts[file] = frameCount
            case let .contiguousRun(track, timestamp, _, file, fileFrameOffset):
                buffers[track, default: []].append(JournaledBuffer(timestamp: timestamp, file: file, fileFrameOffset: fileFrameOffset))
            case let .gap(track, startedAt, duration, file, fileFrameOffset):
                // The gap record's own timestamp is where delivery *stopped*; the
                // buffer that reported it begins one gap-duration later.
                var buffer = JournaledBuffer(timestamp: startedAt + duration, file: file ?? "", fileFrameOffset: fileFrameOffset ?? 0)
                buffer.precedingGap = duration
                buffers[track, default: []].append(buffer)
            case let .overlap(track, startedAt, duration, file, fileFrameOffset):
                var buffer = JournaledBuffer(timestamp: startedAt, file: file ?? "", fileFrameOffset: fileFrameOffset ?? 0)
                buffer.precedingOverlap = duration
                buffers[track, default: []].append(buffer)
            case let .formatChange(track, at, from, to):
                sessionDiagnostics.append(TimelineDiagnostic(
                    code: "format-change",
                    message: "\(track.rawValue) changed format at \(at.seconds)s from \(from?.description ?? "unknown") to \(to?.description ?? "unknown"); the run is broken there and each side is converted from its own rate."
                ))
            case let .interruption(reason):
                sessionDiagnostics.append(TimelineDiagnostic(code: "interruption", message: reason))
            case let .outputRouteChange(_, name):
                // Measured: a route change can leave the timestamps perfectly
                // continuous while punching a hole in the audio content. The timeline
                // must not invent a gap here, but the AEC stage needs the marker.
                sessionDiagnostics.append(TimelineDiagnostic(
                    code: "output-route-change",
                    message: "output routed to \(name ?? "an unnamed device"); timestamps stay continuous, so no silence is inserted, but this is an AEC reconvergence point and a possible content gap."
                ))
            case let .recoveredActiveSegments(files):
                sessionDiagnostics.append(TimelineDiagnostic(code: "recovered-segments", message: "recovered after an unclean shutdown: \(files.joined(separator: ", "))"))
            case .sessionCreated:
                break
            }
        }

        for (event, count) in journal.unrecognized.sorted(by: { $0.key < $1.key }) {
            sessionDiagnostics.append(TimelineDiagnostic(code: "unrecognized-journal-event", message: "\(count) \(event) record(s) were not modelled by the timeline builder"))
        }
        if !journal.malformedLines.isEmpty {
            sessionDiagnostics.append(TimelineDiagnostic(code: "malformed-journal-line", message: "lines \(journal.malformedLines.map(String.init).joined(separator: ", ")) were not decodable JSON"))
        }

        let captureTracks: [RecorderTrackKind] = [.system, .microphone]
        let present = captureTracks.filter { !(buffers[$0]?.isEmpty ?? true) }
        guard !present.isEmpty else { throw TimelineBuilderError.noCaptureTracks }

        // One origin for the whole session: the earliest first timestamp any track
        // reported. Tracks are never aligned to each other's first sample.
        let origin = present.compactMap { firstTimestamps[$0] ?? buffers[$0]?.first?.timestamp }.min() ?? .zero

        var tracks: [TrackTimeline] = []
        for track in present {
            guard var trackBuffers = buffers[track], !trackBuffers.isEmpty else { continue }
            // Journal order is write order — one writer queue per session — and it is
            // what makes each buffer's length the distance to the next one's file
            // offset. Sorting by timestamp would be wrong here rather than merely
            // redundant: an overlapping buffer is journaled *after* the one it
            // overlaps but timestamped *before* it, so sorting would swap the pair and
            // turn both lengths negative.
            try resolveFrameCounts(&trackBuffers, segmentFrameCounts: segmentFrameCounts, captureDirectory: captureDirectory)
            tracks.append(try makeTrackTimeline(
                track: track,
                buffers: trackBuffers,
                firstTimestamp: firstTimestamps[track] ?? trackBuffers[0].timestamp,
                origin: origin,
                segmentFormats: segmentFormats,
                captureDirectory: captureDirectory,
                options: options
            ))
        }

        return SessionTimeline(
            origin: origin,
            tracks: tracks.sorted { $0.track.rawValue < $1.track.rawValue },
            outputFrameCount: tracks.map(\.outputFrameCount).max() ?? 0,
            diagnostics: sessionDiagnostics
        )
    }

    /// A journal record says where a buffer starts inside its segment but not how
    /// long it is. The length is the distance to the next buffer in the same file,
    /// and for the last one the segment's own total.
    private static func resolveFrameCounts(
        _ buffers: inout [JournaledBuffer],
        segmentFrameCounts: [String: Int64],
        captureDirectory: URL
    ) throws {
        var segmentTotals = segmentFrameCounts
        for index in buffers.indices {
            let buffer = buffers[index]
            let next = index + 1 < buffers.count ? buffers[index + 1] : nil
            if let next, next.file == buffer.file {
                buffers[index].frameCount = max(0, next.fileFrameOffset - buffer.fileFrameOffset)
                continue
            }
            // Last buffer of this segment: fall back to the segment's frame count,
            // and to the file itself when the session died before it was closed.
            let total: Int64
            if let recorded = segmentTotals[buffer.file] {
                total = recorded
            } else {
                let url = captureDirectory.appendingPathComponent(buffer.file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TimelineBuilderError.missingSegment(buffer.file)
                }
                let reader = try CAFSegmentReader(url: url)
                total = reader.frameCount
                try? reader.close()
                segmentTotals[buffer.file] = total
            }
            buffers[index].frameCount = max(0, total - buffer.fileFrameOffset)
        }
    }

    private static func makeTrackTimeline(
        track: RecorderTrackKind,
        buffers: [JournaledBuffer],
        firstTimestamp: RationalTime,
        origin: RationalTime,
        segmentFormats: [String: CaptureAudioFormat],
        captureDirectory: URL,
        options: TimelineBuilderOptions
    ) throws -> TrackTimeline {
        var diagnostics: [TimelineDiagnostic] = []
        var formats: [String: CaptureAudioFormat] = segmentFormats
        func format(of file: String) throws -> CaptureAudioFormat {
            if let known = formats[file] { return known }
            let url = captureDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw TimelineBuilderError.missingSegment(file) }
            let reader = try CAFSegmentReader(url: url)
            defer { try? reader.close() }
            formats[file] = reader.format
            return reader.format
        }

        // Group buffers into runs. A run breaks at a journaled gap, a journaled
        // overlap, or a format change; it never breaks merely because a segment
        // rotated, because a bounded-interval rotation is contiguous audio.
        struct PlannedRun {
            var startTimestamp: RationalTime
            var format: CaptureAudioFormat
            var extents: [TimelineExtent]
            var trimmedLeadingFrames: Int64
        }
        var plannedRuns: [PlannedRun] = []
        var plannedGaps: [(start: RationalTime, duration: RationalTime)] = []
        var totalOverlapSeconds = 0.0

        for buffer in buffers where buffer.frameCount > 0 {
            let bufferFormat = try format(of: buffer.file)
            var startTimestamp = buffer.timestamp
            var trimmed: Int64 = 0
            var breaksRun = plannedRuns.isEmpty

            if let gap = buffer.precedingGap {
                plannedGaps.append((start: buffer.timestamp - gap, duration: gap))
                breaksRun = true
            }
            if let overlap = buffer.precedingOverlap {
                // Never move audio earlier and never overwrite what is already placed:
                // trim the duplicated head off the later buffer and start it where the
                // previous run actually ended.
                totalOverlapSeconds += overlap.seconds
                trimmed = min(buffer.frameCount, max(0, Int64((overlap.seconds * Double(bufferFormat.sampleRate)).rounded())))
                startTimestamp = buffer.timestamp + RationalTime.duration(frames: trimmed, atSampleRate: bufferFormat.sampleRate)
                breaksRun = true
                diagnostics.append(TimelineDiagnostic(
                    code: "overlap-trimmed",
                    message: "\(String(format: "%.6f", overlap.seconds))s of overlap at \(String(format: "%.6f", buffer.timestamp.seconds))s: \(trimmed) frame(s) were trimmed from the later buffer rather than shifting audio earlier."
                ))
            }
            if let last = plannedRuns.last, last.format != bufferFormat { breaksRun = true }

            let usableFrames = buffer.frameCount - trimmed
            guard usableFrames > 0 else { continue }
            let extent = TimelineExtent(file: buffer.file, fileFrameOffset: buffer.fileFrameOffset + trimmed, frameCount: usableFrames)

            if breaksRun || plannedRuns.isEmpty {
                plannedRuns.append(PlannedRun(startTimestamp: startTimestamp, format: bufferFormat, extents: [extent], trimmedLeadingFrames: trimmed))
            } else {
                var current = plannedRuns[plannedRuns.count - 1]
                if var previous = current.extents.last, previous.file == extent.file,
                   previous.fileFrameOffset + previous.frameCount == extent.fileFrameOffset {
                    previous = TimelineExtent(file: previous.file, fileFrameOffset: previous.fileFrameOffset, frameCount: previous.frameCount + extent.frameCount)
                    current.extents[current.extents.count - 1] = previous
                } else {
                    current.extents.append(extent)
                }
                plannedRuns[plannedRuns.count - 1] = current
            }
        }

        guard !plannedRuns.isEmpty else {
            throw TimelineBuilderError.noCaptureTracks
        }

        // Drift is measured over buffers, not runs: a session that never lost a
        // sample is one single run, and that is exactly the case where a clock
        // difference has the whole meeting to accumulate.
        let deliveredBuffers = buffers.filter { $0.frameCount > 0 }
        let drift = measureDrift(
            buffers: try deliveredBuffers.map { (timestamp: $0.timestamp, frames: $0.frameCount, rate: try format(of: $0.file).sampleRate) },
            gapSeconds: plannedGaps.reduce(0) { $0 + $1.duration.seconds },
            overlapSeconds: totalOverlapSeconds,
            options: options,
            diagnostics: &diagnostics
        )

        // Place every run on the 48 kHz grid from its own timestamp against the one
        // session origin, then give it the frame count its native samples convert to.
        var runs: [TimelineRun] = []
        var cursor: Int64 = 0
        for planned in plannedRuns {
            let nativeFrames = planned.extents.reduce(0) { $0 + $1.frameCount }
            var start = (planned.startTimestamp - origin).frameIndex(atSampleRate: timelineSampleRate)
            if start < cursor {
                // Rounding, not a discontinuity: a run may not begin before the one
                // before it ended, and shortening the earlier run is never allowed.
                if start < cursor - 1 {
                    diagnostics.append(TimelineDiagnostic(
                        code: "run-start-clamped",
                        message: "a run timestamped at \(String(format: "%.6f", planned.startTimestamp.seconds))s resolved \(cursor - start) frame(s) before the end of the previous run and was placed at the boundary instead."
                    ))
                }
                start = cursor
            }
            let resampler = SincResampler(
                inputSampleRate: planned.format.sampleRate,
                outputSampleRate: timelineSampleRate,
                driftRatio: drift.appliedRatio,
                channelCount: planned.format.channelCount,
                contextFrames: options.resamplerContextFrames
            )
            let outputFrames = resampler.outputFrameCount(forInputFrames: nativeFrames)
            runs.append(TimelineRun(
                startTimestamp: planned.startTimestamp,
                format: planned.format,
                extents: planned.extents,
                trimmedLeadingFrames: planned.trimmedLeadingFrames,
                outputStartFrame: start,
                outputFrameCount: outputFrames
            ))
            cursor = start + outputFrames
        }

        let gaps: [TimelineGap] = plannedGaps.map { gap in
            let start = (gap.start - origin).frameIndex(atSampleRate: timelineSampleRate)
            let end = (gap.start + gap.duration - origin).frameIndex(atSampleRate: timelineSampleRate)
            return TimelineGap(
                startTimestamp: gap.start,
                duration: gap.duration,
                outputStartFrame: start,
                outputFrameCount: max(0, end - start),
                reason: "journaled capture gap"
            )
        }

        let nativeFormat = runs[0].format
        let channelCount = runs.map(\.format.channelCount).max() ?? nativeFormat.channelCount
        if runs.contains(where: { $0.format.channelCount != channelCount }) {
            diagnostics.append(TimelineDiagnostic(
                code: "channel-count-change",
                message: "the track changes channel count mid-session; runs with fewer channels are widened by repeating the available channel, and the manifest records the canonical \(channelCount)-channel output."
            ))
        }
        let leading = (firstTimestamp - origin).frameIndex(atSampleRate: timelineSampleRate)

        return TrackTimeline(
            track: track,
            nativeFormat: nativeFormat,
            firstTimestamp: firstTimestamp,
            leadingSilenceFrames: max(0, leading),
            runs: runs,
            gaps: gaps,
            drift: drift,
            resamplerContextFrames: options.resamplerContextFrames,
            outputFrameCount: cursor,
            channelCount: channelCount,
            diagnostics: diagnostics
        )
    }

    /// Compares timestamp progression with the samples actually delivered.
    ///
    /// The timestamp span runs from the first buffer to the last, and the delivered
    /// span accounts for that same interval out of frame counts plus journaled gaps
    /// minus journaled overlaps. A ratio other than one means the capture clock and
    /// the media clock disagree, and the correction is applied by resampling the
    /// processing copy at that constant ratio — a gradual stretch across the whole
    /// track, never a block dropped or repeated at one point.
    private static func measureDrift(
        buffers: [(timestamp: RationalTime, frames: Int64, rate: Int)],
        gapSeconds: Double,
        overlapSeconds: Double,
        options: TimelineBuilderOptions,
        diagnostics: inout [TimelineDiagnostic]
    ) -> DriftMeasurement {
        func measurement(_ ppm: Double, _ ratio: Double, _ corrected: Bool, _ rationale: String, span: Double, delivered: Double) -> DriftMeasurement {
            DriftMeasurement(timestampSpanSeconds: span, deliveredSpanSeconds: delivered, partsPerMillion: ppm, appliedRatio: ratio, corrected: corrected, rationale: rationale)
        }
        guard let first = buffers.first, let last = buffers.last, buffers.count > 1 else {
            return measurement(0, 1, false, "fewer than two buffers: there is no timestamp progression to compare against", span: 0, delivered: 0)
        }
        let timestampSpan = (last.timestamp - first.timestamp).seconds
        // The timestamp span runs from the first buffer's start to the last buffer's
        // start, so the samples that should account for it are every buffer's but the
        // last one's, plus the intervals the journal says nothing was delivered.
        let deliveredAudio = buffers.dropLast().reduce(0.0) { $0 + Double($1.frames) / Double($1.rate) }
        let delivered = deliveredAudio + gapSeconds - overlapSeconds
        guard delivered > 0, timestampSpan > 0 else {
            return measurement(0, 1, false, "no delivered audio to compare timestamps against", span: timestampSpan, delivered: delivered)
        }

        let ratio = timestampSpan / delivered
        let ppm = (ratio - 1) * 1_000_000
        guard abs(ppm) >= options.driftCorrectionThresholdPPM else {
            return measurement(ppm, 1, false, "measured \(String(format: "%.3f", ppm)) ppm, inside the \(options.driftCorrectionThresholdPPM) ppm threshold", span: timestampSpan, delivered: delivered)
        }
        guard timestampSpan >= options.minimumDriftMeasurementSeconds else {
            let rationale = "measured \(String(format: "%.3f", ppm)) ppm over only \(String(format: "%.3f", timestampSpan))s, below the \(options.minimumDriftMeasurementSeconds)s needed to extrapolate a ratio to the whole track"
            diagnostics.append(TimelineDiagnostic(code: "drift-not-corrected", message: rationale))
            return measurement(ppm, 1, false, rationale, span: timestampSpan, delivered: delivered)
        }
        guard abs(ppm) <= options.maximumDriftCorrectionPPM else {
            let rationale = "measured \(String(format: "%.3f", ppm)) ppm, beyond the \(options.maximumDriftCorrectionPPM) ppm ceiling; this is a damaged journal rather than a clock difference, so the samples are left at their native rate"
            diagnostics.append(TimelineDiagnostic(code: "drift-implausible", message: rationale))
            return measurement(ppm, 1, false, rationale, span: timestampSpan, delivered: delivered)
        }
        return measurement(ppm, ratio, true, "measured \(String(format: "%.3f", ppm)) ppm over \(String(format: "%.3f", timestampSpan))s; the processing copy is resampled at that constant ratio", span: timestampSpan, delivered: delivered)
    }
}
