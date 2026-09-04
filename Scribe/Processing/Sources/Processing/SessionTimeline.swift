import Foundation
import ScribeAppCore

/// The processing timeline's sample rate. Everything the offline pipeline works
/// on lives on this grid; the archive keeps its native rates.
public let timelineSampleRate = 48_000

/// A contiguous stretch of one CAF segment that belongs to a run.
public struct TimelineExtent: Sendable, Equatable {
    public let file: String
    public let fileFrameOffset: Int64
    public let frameCount: Int64
}

/// A maximal stretch of capture with no journaled discontinuity inside it.
///
/// Runs never span a gap. That is what makes "insert silence only for documented
/// missing intervals, and never concatenate across a gap" structural rather than
/// a rule the reader has to remember.
public struct TimelineRun: Sendable, Equatable {
    public let startTimestamp: RationalTime
    public let format: CaptureAudioFormat
    public let extents: [TimelineExtent]
    /// Frames trimmed from the front because the journal recorded an overlap.
    public let trimmedLeadingFrames: Int64
    /// Where this run begins on the 48 kHz session grid.
    public let outputStartFrame: Int64
    /// How many 48 kHz frames it occupies after conversion and drift correction.
    public let outputFrameCount: Int64

    public var nativeFrameCount: Int64 { extents.reduce(0) { $0 + $1.frameCount } }
}

/// A journaled interval during which a track delivered nothing.
public struct TimelineGap: Sendable, Equatable {
    public let startTimestamp: RationalTime
    public let duration: RationalTime
    public let outputStartFrame: Int64
    public let outputFrameCount: Int64
    public let reason: String
}

/// The drift the journal's timestamps show against the samples actually delivered.
public struct DriftMeasurement: Sendable, Equatable {
    /// Seconds between the first and last buffer's presentation timestamps.
    public let timestampSpanSeconds: Double
    /// The same span accounted for from frame counts and journaled gaps.
    public let deliveredSpanSeconds: Double
    public let partsPerMillion: Double
    /// The factor applied to the processing copy. Exactly 1 when no correction was made.
    public let appliedRatio: Double
    public let corrected: Bool
    /// Why a measured drift was or was not acted on.
    public let rationale: String
}

/// Anything the builder had to decide that a reviewer or the manifest should see.
public struct TimelineDiagnostic: Sendable, Equatable {
    public let code: String
    public let message: String
}

/// One reconstructed track: where it starts, what it contains, and what it cost.
public struct TrackTimeline: Sendable, Equatable {
    public let track: RecorderTrackKind
    public let nativeFormat: CaptureAudioFormat
    /// This track's own first presentation timestamp, unmodified.
    public let firstTimestamp: RationalTime
    /// 48 kHz frames between the session origin and this track's first sample.
    /// The measured captures put the microphone anywhere from 0.123 s to 2.594 s
    /// behind the system track, so this is preserved per session, never assumed.
    public let leadingSilenceFrames: Int64
    public let runs: [TimelineRun]
    public let gaps: [TimelineGap]
    public let drift: DriftMeasurement
    public let resamplerContextFrames: Int
    /// Total 48 kHz frames from the session origin to the end of the last run.
    public let outputFrameCount: Int64
    public let channelCount: Int
    public let diagnostics: [TimelineDiagnostic]

    public var durationSeconds: Double { Double(outputFrameCount) / Double(timelineSampleRate) }
}

/// The whole session on one 48 kHz grid.
public struct SessionTimeline: Sendable, Equatable {
    /// The single origin every track is measured from: the earliest first
    /// presentation timestamp in the session.
    public let origin: RationalTime
    public let tracks: [TrackTimeline]
    public let outputFrameCount: Int64
    public let diagnostics: [TimelineDiagnostic]

    public func track(_ kind: RecorderTrackKind) -> TrackTimeline? {
        tracks.first { $0.track == kind }
    }

    public var durationSeconds: Double { Double(outputFrameCount) / Double(timelineSampleRate) }
}

/// Tunables for drift handling. The defaults come from the measurements in
/// `docs/feasibility/capture-timing.md`.
public struct TimelineBuilderOptions: Sendable, Equatable {
    /// Drift below this is left alone: correcting it would be acting on noise.
    public var driftCorrectionThresholdPPM: Double
    /// A ratio measured over less than this many seconds is not extrapolated to
    /// the whole session. Every drift number in the feasibility document comes from
    /// a run of 90 seconds or less, so a confident correction needs a real span.
    public var minimumDriftMeasurementSeconds: Double
    /// A guard against a corrupt journal turning into a wildly stretched track.
    public var maximumDriftCorrectionPPM: Double
    /// Source frames of kernel context for the resampler.
    public var resamplerContextFrames: Int

    public init(
        driftCorrectionThresholdPPM: Double = 1,
        minimumDriftMeasurementSeconds: Double = 5,
        maximumDriftCorrectionPPM: Double = 10_000,
        resamplerContextFrames: Int = 32
    ) {
        self.driftCorrectionThresholdPPM = driftCorrectionThresholdPPM
        self.minimumDriftMeasurementSeconds = minimumDriftMeasurementSeconds
        self.maximumDriftCorrectionPPM = maximumDriftCorrectionPPM
        self.resamplerContextFrames = resamplerContextFrames
    }
}

public enum TimelineBuilderError: Error, Equatable, CustomStringConvertible {
    case missingJournal(String)
    case noCaptureTracks
    case missingSegment(String)
    case formatChangedWithinRun(RecorderTrackKind)

    public var description: String {
        switch self {
        case .missingJournal(let path): return "no capture journal at \(path)"
        case .noCaptureTracks: return "the journal records no capture track"
        case .missingSegment(let file): return "the journal references \(file), which is not in the capture directory"
        case .formatChangedWithinRun(let track): return "the \(track.rawValue) track changed format without a journaled boundary"
        }
    }
}
