import Foundation

/// One analysis window's answer to "how far behind the reference does this
/// microphone's echo sit?".
///
/// A window that could not answer still appears, carrying its rejection reason.
/// Section 5 asks for confidence checks that reject local speech and silence, and
/// a rejected window is evidence about the session, not an absence of evidence.
public struct DelayWindow: Sendable, Equatable {
    /// Frames from the session origin at which this window starts.
    public let startFrame: Int64
    public let frameCount: Int
    public let delaySamples: Int?
    public let correlation: Double?
    /// The strongest non-neighbouring competing peak. A reverb tail is not a
    /// competitor; an unrelated periodic match is.
    public let runnerUpCorrelation: Double?
    public let referenceLevelDbFS: Double?
    public let microphoneLevelDbFS: Double?
    public let rejection: String?

    public var margin: Double? {
        guard let correlation, let runnerUpCorrelation else { return nil }
        return correlation - runnerUpCorrelation
    }

    public var startSeconds: Double { Double(startFrame) / Double(timelineSampleRate) }
}

/// A stretch of the session over which one render-to-capture delay is declared.
public struct RenderDelaySegment: Sendable, Equatable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let delaySamples: Int
    public let correlation: Double
    public let margin: Double
    public let confidence: Double
    /// How many analysis windows stand behind this segment.
    public let windowCount: Int
    /// `single-window-confident` or `multi-window-agreement`; see ``RenderDelayEstimator``.
    public let basis: String

    public var delayMilliseconds: Double { Double(delaySamples) * 1_000 / Double(timelineSampleRate) }
    public var startSeconds: Double { Double(startFrame) / Double(timelineSampleRate) }
}

/// What the session's own audio says should happen to the microphone track.
///
/// Section 5 requires uncertain delay to be treated conservatively and forbids
/// publishing a raw doubled mix as a cleaned result. That makes three outcomes,
/// not two: two of them legitimately pass the microphone through untouched, and
/// only the third — echo is evidently present but its delay cannot be pinned
/// down — is a failure.
public enum EchoPathDecision: Sendable, Equatable {
    /// The reference never carried audio, so no echo can exist to cancel.
    case noReferenceActivity
    /// The reference played but nothing correlated with it reached the microphone:
    /// headphones, a muted speaker, or a microphone that simply does not hear it.
    case noEchoPath(bestCorrelation: Double?)
    /// A delay was established; AEC3 runs against these segments.
    case cancel(segments: [RenderDelaySegment])
    /// Something correlated with the reference is in the microphone, but no window
    /// could establish where. Cancelling on a guessed delay risks damaging speech
    /// and passing it through risks publishing a doubled mix, so the job fails.
    case uncertain(reason: String, bestCorrelation: Double?, bestMargin: Double?)

    public var cancels: Bool { if case .cancel = self { return true } else { return false } }
    public var isFailure: Bool { if case .uncertain = self { return true } else { return false } }

    public var summary: String {
        switch self {
        case .noReferenceActivity:
            return "no-reference-activity"
        case .noEchoPath:
            return "no-echo-path-detected"
        case .cancel(let segments):
            return "cancel:\(segments.count)-segment\(segments.count == 1 ? "" : "s")"
        case .uncertain:
            return "uncertain-delay"
        }
    }
}

/// Everything the estimation pass learned, ready for the canceller and the manifest.
public struct RenderDelayPlan: Sendable, Equatable {
    public let decision: EchoPathDecision
    public let windows: [DelayWindow]
    public let referenceActiveSeconds: Double
    public let analyzedSeconds: Double
    public let bestCorrelation: Double?
    public let bestMargin: Double?
    public let options: RenderDelayEstimator.Options

    /// The delay in force at `frame`, or nil when no cancellation is planned.
    public func delaySamples(atFrame frame: Int64) -> Int? {
        guard case .cancel(let segments) = decision else { return nil }
        return segments.last { $0.startFrame <= frame }?.delaySamples ?? segments.first?.delaySamples
    }

    /// Frames at which the declared delay changes, which is where AEC3's adapted
    /// filter no longer describes the path it is looking at.
    public var delayChangeFrames: [Int64] {
        guard case .cancel(let segments) = decision else { return [] }
        return segments.dropFirst().map(\.startFrame)
    }
}

/// Estimates the render-to-capture delay across a whole session.
///
/// The feasibility harness in `Tools/AECHarness` established the per-window test
/// this reuses — a decimated broad search refined at full rate, accepted only from
/// an active window with strong correlation and a clear non-neighbouring peak
/// margin. `docs/feasibility/aec-results.md` also recorded what that test alone
/// cannot do: on the double-talk fixture no single window is clean enough, so the
/// harness bypassed the fixture entirely.
///
/// Offline there is a second, stronger form of evidence available that an online
/// estimator cannot use: the whole session at once. Several *disjoint* windows,
/// none individually convincing, that nevertheless land on the same lag are not
/// agreeing by accident — local speech is uncorrelated with playback and moves the
/// apparent peak around, so it cannot manufacture that agreement. This estimator
/// therefore accepts a delay on either route, and records which one it used.
public struct RenderDelayEstimator: Sendable {
    public struct Options: Sendable, Equatable {
        /// Analysis window length. One second, as in the feasibility harness.
        public var windowFrames: Int
        /// Smallest gap between window starts.
        public var minimumStrideFrames: Int
        /// A cap on total windows, so a two-hour session costs the same as a short
        /// one. AEC3 tracks fine movement itself; this pass only has to find the
        /// bulk delay and the places it visibly moves.
        public var maximumWindows: Int
        /// Widest delay searched: 120 ms, the harness's range.
        public var maximumDelaySamples: Int
        /// A window quieter than this on either track cannot calibrate anything.
        public var activityFloorDbFS: Double
        /// Single-window acceptance, from the feasibility harness.
        public var minimumCorrelation: Double
        public var minimumPeakMargin: Double
        /// Multi-window agreement: this many disjoint windows landing within
        /// ``agreementToleranceSamples`` of each other, at these weaker per-window
        /// bars. The same tolerance is what separates one echo path from another,
        /// so a lag that moves by less than it has not really moved.
        public var minimumAgreeingWindows: Int
        public var agreementToleranceSamples: Int
        public var agreementMinimumCorrelation: Double
        public var agreementMinimumPeakMargin: Double
        /// Correlation at or above which the microphone is judged to contain
        /// *something* related to the reference. Matches `Tools/AudioMetrics`'
        /// own far-end presence threshold so the pipeline and the gate agree on
        /// when an echo path exists at all.
        public var echoPresenceCorrelation: Double
        /// The shortest delay an acoustic echo path can physically have.
        ///
        /// Sound has to leave a speaker, cross a room and be captured, on top of
        /// whatever the output device buffers; the far-end-only calibration in
        /// `docs/feasibility/aec-results.md` measured 29.94 ms on built-in
        /// hardware. A correlation peak at or near zero lag is therefore not an
        /// echo — it is the reference and the microphone sharing content for some
        /// other reason — and acting on it would point AEC3 at the near end.
        public var minimumPlausibleDelaySamples: Int

        public init(
            windowFrames: Int = timelineSampleRate,
            minimumStrideFrames: Int = timelineSampleRate / 2,
            maximumWindows: Int = 240,
            maximumDelaySamples: Int = 5_760,
            activityFloorDbFS: Double = -55,
            minimumCorrelation: Double = 0.65,
            minimumPeakMargin: Double = 0.10,
            minimumAgreeingWindows: Int = 3,
            agreementToleranceSamples: Int = 480,
            agreementMinimumCorrelation: Double = 0.25,
            agreementMinimumPeakMargin: Double = 0.05,
            echoPresenceCorrelation: Double = 0.15,
            minimumPlausibleDelaySamples: Int = 96
        ) {
            self.windowFrames = windowFrames
            self.minimumStrideFrames = minimumStrideFrames
            self.maximumWindows = maximumWindows
            self.maximumDelaySamples = maximumDelaySamples
            self.activityFloorDbFS = activityFloorDbFS
            self.minimumCorrelation = minimumCorrelation
            self.minimumPeakMargin = minimumPeakMargin
            self.minimumAgreeingWindows = minimumAgreeingWindows
            self.agreementToleranceSamples = agreementToleranceSamples
            self.agreementMinimumCorrelation = agreementMinimumCorrelation
            self.agreementMinimumPeakMargin = agreementMinimumPeakMargin
            self.echoPresenceCorrelation = echoPresenceCorrelation
            self.minimumPlausibleDelaySamples = minimumPlausibleDelaySamples
        }
    }

    public let options: Options
    private let stride: Int

    /// `expectedFrameCount` only sets the window stride, so an estimate is never
    /// wrong because the caller's guess at the length was.
    public init(options: Options = Options(), expectedFrameCount: Int64) {
        self.options = options
        let windows = max(1, options.maximumWindows)
        let byLength = Int(max(1, expectedFrameCount / Int64(windows)))
        self.stride = max(options.minimumStrideFrames, byLength)
    }

    // The buffer holds one window plus the widest lag searched, because a lag of
    // L needs reference samples from L before the window's first capture sample,
    // plus one stride so the next window is still whole after a trim.
    private var bufferCapacity: Int { options.windowFrames + options.maximumDelaySamples + stride }

    /// Runs the whole estimation pass over two block streams that advance together.
    ///
    /// `next` returns the next `(reference, microphone)` mono block on the session
    /// grid, or nil at the end. Both must be the same length. Memory stays at one
    /// window plus the lag range no matter how long the session is.
    public func plan(nextBlock: () throws -> (reference: [Float], microphone: [Float])?) rethrows -> RenderDelayPlan {
        var reference: [Float] = []
        var microphone: [Float] = []
        reference.reserveCapacity(bufferCapacity + timelineSampleRate / 100)
        microphone.reserveCapacity(bufferCapacity + timelineSampleRate / 100)

        var windows: [DelayWindow] = []
        var bufferStartFrame: Int64 = 0
        var totalFrames: Int64 = 0
        var referenceActiveFrames: Int64 = 0
        var nextWindowStartFrame: Int64 = 0

        while let block = try nextBlock() {
            let count = min(block.reference.count, block.microphone.count)
            guard count > 0 else { continue }
            reference.append(contentsOf: block.reference.prefix(count))
            microphone.append(contentsOf: block.microphone.prefix(count))
            totalFrames += Int64(count)
            if let level = Self.level(block.reference.prefix(count)), level > options.activityFloorDbFS {
                referenceActiveFrames += Int64(count)
            }

            // Evaluate every window whose full extent — the window plus the lag
            // context that precedes it — is now in the buffer.
            while nextWindowStartFrame + Int64(options.windowFrames) <= totalFrames {
                let offset = Int(nextWindowStartFrame - bufferStartFrame)
                if offset >= 0 {
                    windows.append(evaluate(
                        reference: reference,
                        microphone: microphone,
                        windowOffset: offset,
                        startFrame: nextWindowStartFrame
                    ))
                }
                nextWindowStartFrame += Int64(stride)
            }

            if reference.count > bufferCapacity {
                let discard = reference.count - bufferCapacity
                reference.removeFirst(discard)
                microphone.removeFirst(discard)
                bufferStartFrame += Int64(discard)
            }
        }

        // A short session still deserves one look, even if it never filled a window.
        if windows.isEmpty, totalFrames >= 960 {
            windows.append(evaluate(
                reference: reference,
                microphone: microphone,
                windowOffset: 0,
                startFrame: bufferStartFrame,
                frameCount: reference.count
            ))
        }

        return makePlan(
            windows: windows,
            totalFrames: totalFrames,
            referenceActiveFrames: referenceActiveFrames
        )
    }

    private func evaluate(
        reference: [Float],
        microphone: [Float],
        windowOffset: Int,
        startFrame: Int64,
        frameCount: Int? = nil
    ) -> DelayWindow {
        let length = min(frameCount ?? options.windowFrames, microphone.count - windowOffset)
        let start = windowOffset
        let end = windowOffset + length
        guard length > 0 else {
            return DelayWindow(startFrame: startFrame, frameCount: 0, delaySamples: nil, correlation: nil, runnerUpCorrelation: nil, referenceLevelDbFS: nil, microphoneLevelDbFS: nil, rejection: "empty window")
        }
        let referenceLevel = Self.level(reference[start..<end])
        let microphoneLevel = Self.level(microphone[start..<end])
        guard (referenceLevel ?? -.infinity) > options.activityFloorDbFS,
              (microphoneLevel ?? -.infinity) > options.activityFloorDbFS else {
            return DelayWindow(startFrame: startFrame, frameCount: length, delaySamples: nil, correlation: nil, runnerUpCorrelation: nil, referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, rejection: "silence or near-silence is not a valid delay-calibration region")
        }

        // Decimate for the broad search, then evaluate a narrow band at full rate.
        // This is the feasibility harness's search, unchanged; only the decision
        // taken on its result is new.
        let factor = 8
        let coarseReference = Self.decimate(reference, factor: factor)
        let coarseMicrophone = Self.decimate(microphone, factor: factor)
        guard let coarse = Self.bestAndRunnerUp(
            reference: coarseReference, microphone: coarseMicrophone,
            start: start / factor, end: min(coarseMicrophone.count, end / factor),
            lags: 0...(options.maximumDelaySamples / factor), separation: 60
        ) else {
            return DelayWindow(startFrame: startFrame, frameCount: length, delaySamples: nil, correlation: nil, runnerUpCorrelation: nil, referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, rejection: "no overlapping active samples in delay-calibration window")
        }
        let center = coarse.best.lag * factor
        let low = max(0, center - factor * 2)
        let high = min(options.maximumDelaySamples, center + factor * 2)
        guard let refined = Self.bestAndRunnerUp(
            reference: reference, microphone: microphone,
            start: start, end: end, lags: low...high, separation: 480
        ) else {
            return DelayWindow(startFrame: startFrame, frameCount: length, delaySamples: nil, correlation: nil, runnerUpCorrelation: nil, referenceLevelDbFS: referenceLevel, microphoneLevelDbFS: microphoneLevel, rejection: "no full-rate overlap in delay-calibration window")
        }
        let runnerUp = max(coarse.runnerUp.correlation, refined.runnerUp.correlation)
        return DelayWindow(
            startFrame: startFrame,
            frameCount: length,
            delaySamples: refined.best.lag,
            correlation: refined.best.correlation,
            runnerUpCorrelation: runnerUp.isFinite ? runnerUp : 0,
            referenceLevelDbFS: referenceLevel,
            microphoneLevelDbFS: microphoneLevel,
            rejection: nil
        )
    }

    private func makePlan(windows: [DelayWindow], totalFrames: Int64, referenceActiveFrames: Int64) -> RenderDelayPlan {
        let analyzedSeconds = Double(totalFrames) / Double(timelineSampleRate)
        let referenceActiveSeconds = Double(referenceActiveFrames) / Double(timelineSampleRate)
        let measured = windows.filter { $0.correlation != nil }
        let bestCorrelation = measured.compactMap(\.correlation).max()
        let bestMargin = measured.compactMap(\.margin).max()

        func plan(_ decision: EchoPathDecision) -> RenderDelayPlan {
            RenderDelayPlan(
                decision: decision, windows: windows,
                referenceActiveSeconds: referenceActiveSeconds, analyzedSeconds: analyzedSeconds,
                bestCorrelation: bestCorrelation, bestMargin: bestMargin, options: options
            )
        }

        guard referenceActiveFrames > 0 else { return plan(.noReferenceActivity) }

        let segments = buildSegments(from: windows, totalFrames: totalFrames)
        if !segments.isEmpty { return plan(.cancel(segments: segments)) }

        // Nothing was confident. Whether that is fine or fatal depends entirely on
        // whether an echo path appears to exist: with none, there is nothing a
        // canceller would have removed, and the microphone is already clean.
        //
        // Evidence for one has to be physically possible and has to be seen more
        // than once. A single window agreeing with the reference, at a lag no room
        // could produce, is a coincidence in the material — not a reason to fail a
        // recording and withhold its mix.
        let evidence = measured.filter {
            ($0.delaySamples ?? 0) >= options.minimumPlausibleDelaySamples
                && abs($0.correlation ?? 0) >= options.echoPresenceCorrelation
        }
        let repeated = Self.disjointWindowCount(evidence.sorted { $0.startFrame < $1.startFrame }, minimumStride: options.windowFrames) >= 2
        guard repeated, let best = evidence.compactMap(\.correlation).max() else {
            return plan(.noEchoPath(bestCorrelation: bestCorrelation))
        }
        return plan(.uncertain(
            reason: "reference-correlated content reaches the microphone at \(String(format: "%.3f", best)) correlation across \(evidence.count) windows, but no window established its delay: cancelling on a guessed delay could damage local speech, and passing it through would publish an uncancelled echo",
            bestCorrelation: bestCorrelation,
            bestMargin: bestMargin
        ))
    }

    /// Groups the analysed windows into stretches sharing one delay.
    ///
    /// Clustering happens over the whole session before time is considered. Doing
    /// it the other way round — walking windows in order and starting a new group
    /// whenever the lag jumps — makes one noisy window in the middle of an
    /// otherwise unanimous session split the evidence into two halves, neither of
    /// which is then convincing. Clustering first lets an outlier be an outlier.
    private func buildSegments(from windows: [DelayWindow], totalFrames: Int64) -> [RenderDelaySegment] {
        struct Measured { let window: DelayWindow; let delay: Int; let correlation: Double; let margin: Double; let confident: Bool }
        var measured: [Measured] = []
        for window in windows {
            guard let delay = window.delaySamples, let correlation = window.correlation, let margin = window.margin,
                  delay >= options.minimumPlausibleDelaySamples,
                  correlation >= options.agreementMinimumCorrelation else { continue }
            measured.append(Measured(
                window: window, delay: delay, correlation: correlation, margin: margin,
                confident: correlation >= options.minimumCorrelation && margin >= options.minimumPeakMargin
            ))
        }
        guard !measured.isEmpty else { return [] }

        // Single-linkage clustering on the lag axis: neighbouring lags closer than
        // the tolerance describe the same echo path measured twice.
        var clusters: [[Measured]] = []
        for entry in measured.sorted(by: { $0.delay < $1.delay }) {
            if let last = clusters.last?.last, entry.delay - last.delay <= options.agreementToleranceSamples {
                clusters[clusters.count - 1].append(entry)
            } else {
                clusters.append([entry])
            }
        }

        // A cluster is believable either because one window in it met the
        // feasibility harness's own bar, or because enough non-overlapping windows
        // independently landed on it *and* they are the session's dominant answer.
        // The dominance test is what keeps three coincidences from outvoting the
        // rest of the recording.
        let kept = clusters.filter { cluster in
            if cluster.contains(where: \.confident) { return true }
            let byTime = cluster.map(\.window).sorted { $0.startFrame < $1.startFrame }
            return Self.disjointWindowCount(byTime, minimumStride: options.windowFrames) >= options.minimumAgreeingWindows
                && cluster.count * 2 >= measured.count
        }
        guard !kept.isEmpty else { return [] }

        struct Cluster { let delay: Int; let correlation: Double; let margin: Double; let count: Int; let basis: String }
        let summaries = kept.map { cluster -> Cluster in
            let members = cluster.contains(where: \.confident) ? cluster.filter(\.confident) : cluster
            let delays = members.map(\.delay).sorted()
            let correlations = members.map(\.correlation).sorted()
            let margins = members.map(\.margin).sorted()
            return Cluster(
                delay: delays[delays.count / 2],
                correlation: correlations[correlations.count / 2],
                margin: margins[margins.count / 2],
                count: members.count,
                basis: cluster.contains(where: \.confident) ? "single-window-confident" : "multi-window-agreement"
            )
        }

        // Now place the kept clusters in time. A switch has to persist across at
        // least two windows to be a real move in the echo path rather than one
        // window measuring badly.
        func cluster(for entry: Measured) -> Int? {
            summaries.firstIndex { abs($0.delay - entry.delay) <= options.agreementToleranceSamples }
        }
        let ordered = measured.sorted { $0.window.startFrame < $1.window.startFrame }
        var timeline: [(index: Int, frame: Int64)] = []
        var pendingIndex: Int?
        var pendingFrame: Int64 = 0
        var pendingCount = 0
        for entry in ordered {
            guard let index = cluster(for: entry) else { continue }
            if timeline.last?.index == index { pendingIndex = nil; continue }
            if pendingIndex == index {
                pendingCount += 1
                if pendingCount >= 2 || timeline.isEmpty {
                    timeline.append((index, pendingFrame))
                    pendingIndex = nil
                }
            } else {
                pendingIndex = index
                pendingFrame = entry.window.startFrame
                pendingCount = 1
                if timeline.isEmpty {
                    timeline.append((index, pendingFrame))
                    pendingIndex = nil
                }
            }
        }
        guard !timeline.isEmpty else { return [] }

        return timeline.enumerated().map { position, entry in
            let summary = summaries[entry.index]
            return RenderDelaySegment(
                // The first segment reaches back to the session origin so no block
                // is ever processed without a declared delay.
                startFrame: position == 0 ? 0 : entry.frame,
                endFrame: position + 1 < timeline.count ? timeline[position + 1].frame : totalFrames,
                delaySamples: summary.delay,
                correlation: summary.correlation,
                margin: summary.margin,
                confidence: Self.confidence(correlation: summary.correlation, margin: summary.margin, options: options, windowCount: summary.count),
                windowCount: summary.count,
                basis: summary.basis
            )
        }
    }

    /// How many of these windows share no samples with one another.
    ///
    /// Overlapping windows see much of the same audio, so counting them all would
    /// let one lucky second masquerade as several independent confirmations. Only
    /// the non-overlapping subset is evidence.
    private static func disjointWindowCount(_ windows: [DelayWindow], minimumStride: Int) -> Int {
        guard let first = windows.first else { return 0 }
        var count = 1
        var last = first.startFrame
        for window in windows.dropFirst() where window.startFrame - last >= Int64(minimumStride) {
            count += 1
            last = window.startFrame
        }
        return count
    }

    private static func confidence(correlation: Double, margin: Double, options: Options, windowCount: Int) -> Double {
        let strength = min(1, max(0, (correlation - options.agreementMinimumCorrelation) / (1 - options.agreementMinimumCorrelation)))
        let separation = min(1, max(0, margin / 0.20))
        let support = min(1, Double(windowCount) / Double(max(1, options.minimumAgreeingWindows)))
        return strength * separation * support
    }

    // MARK: - Correlation primitives

    private struct Candidate { let lag: Int; let correlation: Double }
    private struct Pair { let best: Candidate; let runnerUp: Candidate }

    private static func bestAndRunnerUp(
        reference: [Float], microphone: [Float],
        start: Int, end: Int, lags: ClosedRange<Int>, separation: Int
    ) -> Pair? {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(lags.count)
        for lag in lags {
            let lower = max(start, lag)
            let upper = min(end, reference.count + lag)
            guard upper - lower >= 480 else { continue }
            var cross = 0.0, referenceEnergy = 0.0, microphoneEnergy = 0.0
            for index in lower..<upper {
                let r = Double(reference[index - lag]), c = Double(microphone[index])
                cross += r * c
                referenceEnergy += r * r
                microphoneEnergy += c * c
            }
            guard referenceEnergy > 1e-12, microphoneEnergy > 1e-12 else { continue }
            candidates.append(Candidate(lag: lag, correlation: cross / (referenceEnergy * microphoneEnergy).squareRoot()))
        }
        guard let best = candidates.max(by: { $0.correlation < $1.correlation }) else { return nil }
        let runnerUp = candidates.filter { abs($0.lag - best.lag) >= separation }.max(by: { $0.correlation < $1.correlation })
            ?? Candidate(lag: best.lag, correlation: 0)
        return Pair(best: best, runnerUp: runnerUp)
    }

    private static func decimate(_ signal: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return signal }
        var output = [Float]()
        output.reserveCapacity(signal.count / factor)
        var index = 0
        while index + factor <= signal.count {
            var sum: Float = 0
            for offset in 0..<factor { sum += signal[index + offset] }
            output.append(sum / Float(factor))
            index += factor
        }
        return output
    }

    private static func level(_ samples: ArraySlice<Float>) -> Double? {
        guard !samples.isEmpty else { return nil }
        let mean = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        guard mean > 1e-14 else { return nil }
        return 10 * log10(mean)
    }
}
