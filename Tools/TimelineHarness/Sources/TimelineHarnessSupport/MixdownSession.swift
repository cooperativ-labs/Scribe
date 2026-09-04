import AVFAudio
import Foundation
import Processing
import ScribeAppCore

/// Drives `EchoCanceller` and `MixdownService` over a fixture and writes what the
/// implementation-plan section 8 echo and local-speech gates need to score them.
///
/// The synthetic cases go through a synthesized capture archive so the code under
/// test is the production path — `TimelineBuilder`, the delay estimator, AEC3, the
/// mixer, the FLAC encoder — and not a shortcut that reads WAVs directly.
///
/// One deliberate difference from ``FixtureSession``: the microphone track is
/// written starting at the session origin rather than behind it by one of the
/// measured stream offsets. A fixture's `microphone.wav` *is* the echo of its
/// `playback.wav` on a shared time base, so pushing its content later would model
/// a microphone that missed the opening of the meeting, not a late-starting
/// stream. Preserving a real per-track lead is the timeline gate's subject and is
/// measured there; what this harness has to put in front of AEC3 is two tracks
/// separated only by the acoustic delay the fixture declares.
public enum MixdownSession {
    public struct Result: Sendable {
        public let caseID: String
        public let sessionDirectory: URL
        /// The echo-cancelled microphone, before mix gain: the signal the echo and
        /// local-speech gates are defined against.
        public let cleanedMicrophoneURL: URL
        /// `final.flac` decoded back to WAV, for the peak and clipping gates and
        /// for listening.
        public let finalMixURL: URL
        public let finalFLACURL: URL
        public let decision: String
        public let delaySamples: Int?
        public let delayCorrelation: Double?
        public let delayBasis: String?
        public let delaySegments: Int
        public let analysisWindows: Int
        public let processingLatencyFrames: Int
        public let reconvergenceSeconds: [Double]
        public let truePeakBeforeGainDbTP: Double?
        public let appliedPeakGain: Double
        public let echoReturnLossEnhancementDb: Double?
        public let residualEchoLikelihood: Double?
        public let frameCount: Int64
        public let checksum: String
        public let failure: String?
        /// Leading silence the reconstruction preserved on the microphone track,
        /// so a measurement can line the cleaned output up with the source WAV.
        public let microphoneLeadFrames: Int
        /// Every analysis window the estimator looked at, so a decision — and
        /// especially a refusal — can be read rather than guessed at.
        public let windows: [[String: Double]]
        public let windowRejections: [String]
    }

    private static func windowReport(_ plan: RenderDelayPlan) -> ([[String: Double]], [String]) {
        var rows: [[String: Double]] = []
        var rejections: [String] = []
        for window in plan.windows {
            var row: [String: Double] = ["startSeconds": window.startSeconds]
            if let delay = window.delaySamples { row["delaySamples"] = Double(delay) }
            if let correlation = window.correlation { row["correlation"] = correlation }
            if let runnerUp = window.runnerUpCorrelation { row["runnerUp"] = runnerUp }
            if let margin = window.margin { row["margin"] = margin }
            if let level = window.referenceLevelDbFS { row["referenceDb"] = level }
            if let level = window.microphoneLevelDbFS { row["microphoneDb"] = level }
            rows.append(row)
            if let rejection = window.rejection { rejections.append("\(String(format: "%.1f", window.startSeconds))s: \(rejection)") }
        }
        return (rows, rejections)
    }

    /// Runs a synthetic fixture case.
    public static func runFixture(
        fixtureDirectory: URL,
        workingDirectory: URL,
        options: MixdownService.Options = MixdownService.Options()
    ) throws -> Result {
        let truth = try FixtureSession.readGroundTruth(fixtureDirectory: fixtureDirectory)
        let microphone = try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("microphone.wav"))
        let playback = try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("playback.wav"))
        return try run(
            caseID: truth.caseID,
            system: playback,
            microphone: microphone,
            gapIntervals: truth.gapIntervals,
            driftRatio: truth.driftRatio,
            workingDirectory: workingDirectory,
            options: options
        )
    }

    /// Runs a real-room fixture from `Tests/Fixtures/real`, which ships a recorded
    /// `system.wav` / `microphone.wav` pair and no ground truth.
    ///
    /// Each exported WAV begins at its own stream's first sample, so the pair on
    /// disk has had its real relative alignment removed. `fixture.json` still
    /// records what the recorder saw — the first presentation timestamp of each
    /// track on one clock — and the microphone was between 125 and 131 ms behind
    /// the system stream in these three takes. Rebuilding the archive at the
    /// journaled offset is what leaves the acoustic delay, and only the acoustic
    /// delay, between the two tracks; placing both at the origin instead hides a
    /// real 127 ms lead inside a 120 ms delay search and nothing can be found.
    public static func runRealFixture(
        fixtureDirectory: URL,
        workingDirectory: URL,
        options: MixdownService.Options = MixdownService.Options()
    ) throws -> Result {
        try run(
            caseID: fixtureDirectory.lastPathComponent,
            system: try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("system.wav")),
            microphone: try WAVAudio.read(contentsOf: fixtureDirectory.appendingPathComponent("microphone.wav")),
            gapIntervals: [],
            driftRatio: 1,
            microphoneLeadSeconds: try recordedMicrophoneLeadSeconds(fixtureDirectory: fixtureDirectory),
            workingDirectory: workingDirectory,
            options: options
        )
    }

    /// The microphone's journaled start offset behind the system track, in seconds.
    public static func recordedMicrophoneLeadSeconds(fixtureDirectory: URL) throws -> Double {
        let url = fixtureDirectory.appendingPathComponent("fixture.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let timing = object["timing"] as? [String: Any],
              let tracks = timing["tracks"] as? [String: Any],
              let system = tracks["audio"] as? [String: Any],
              let microphone = tracks["microphone"] as? [String: Any],
              let systemFirst = (system["initialTimestampSeconds"] as? NSNumber)?.doubleValue,
              let microphoneFirst = (microphone["initialTimestampSeconds"] as? NSNumber)?.doubleValue else {
            throw HarnessError.message("\(url.path) has no timing.tracks initial timestamps")
        }
        return microphoneFirst - systemFirst
    }

    private static func run(
        caseID: String,
        system: WAVAudio,
        microphone: WAVAudio,
        gapIntervals: [(start: Double, end: Double)],
        driftRatio: Double,
        microphoneLeadSeconds: Double = 0,
        workingDirectory: URL,
        options: MixdownService.Options
    ) throws -> Result {
        let sessionDirectory = workingDirectory.appendingPathComponent("mixdown-\(caseID)", isDirectory: true)
        try? FileManager.default.removeItem(at: sessionDirectory)
        let writer = try CaptureArchiveWriter(sessionDirectory: sessionDirectory)

        let systemChannels = system.channelCount >= 2 ? system.channels : [system.channels[0], system.channels[0]]
        try writeTrack(writer, track: "system", channels: systemChannels, sampleRate: system.sampleRate, bufferFrames: 960, startSeconds: FixtureSession.sessionOriginSeconds, driftRatio: 1, gaps: [])
        // The generator already builds a drifting fixture's echo as though the
        // capture clock ran fast — `echo[n] = playback[(n - delay) / ratio]` — so
        // the microphone samples on disk are what a mismatched device produced.
        // What the archive has to add is the journal's view of that: the device
        // delivered its nominal 48 000 frames over slightly more than a second.
        // Reconstruction then compresses the track back onto true time and the
        // echo lands at a constant delay, which is the whole point of correcting
        // drift before AEC rather than asking AEC3 to track a moving path.
        try writeTrack(writer, track: "microphone", channels: microphone.channels, sampleRate: microphone.sampleRate, bufferFrames: 512, startSeconds: FixtureSession.sessionOriginSeconds + microphoneLeadSeconds, driftRatio: 1 / driftRatio, gaps: gapIntervals)
        try writer.finish()
        try writeManifest(at: sessionDirectory)

        var cleaned: [Float] = []
        let cleanedURL = workingDirectory.appendingPathComponent("\(caseID)-cleaned-microphone.wav")
        let finalMixURL = workingDirectory.appendingPathComponent("\(caseID)-final-mix.wav")
        let finalFLACURL = sessionDirectory.appendingPathComponent(MixdownService.outputFileName)

        do {
            let result = try MixdownService().run(sessionDirectory: sessionDirectory, options: options) { block in
                cleaned.append(contentsOf: block)
            }
            try WAVAudio(sampleRate: 48_000, channels: [cleaned]).write(to: cleanedURL)
            try decodeFLAC(at: finalFLACURL, to: finalMixURL)
            let summary = result.summary
            let report = windowReport(summary.delayPlan)
            let firstSegment: RenderDelaySegment?
            if case .cancel(let segments) = summary.decision { firstSegment = segments.first } else { firstSegment = nil }
            var segmentCount = 0
            if case .cancel(let segments) = summary.decision { segmentCount = segments.count }
            return Result(
                caseID: caseID,
                sessionDirectory: sessionDirectory,
                cleanedMicrophoneURL: cleanedURL,
                finalMixURL: finalMixURL,
                finalFLACURL: finalFLACURL,
                decision: summary.decision.summary,
                delaySamples: firstSegment?.delaySamples,
                delayCorrelation: firstSegment?.correlation,
                delayBasis: firstSegment?.basis,
                delaySegments: segmentCount,
                analysisWindows: summary.delayPlan.windows.count,
                processingLatencyFrames: summary.processingLatencyFrames,
                reconvergenceSeconds: summary.reconvergences.map(\.seconds),
                truePeakBeforeGainDbTP: summary.truePeakBeforeGain > 0 ? 20 * log10(summary.truePeakBeforeGain) : nil,
                appliedPeakGain: summary.appliedPeakGain,
                echoReturnLossEnhancementDb: summary.metrics.echoReturnLossEnhancement,
                residualEchoLikelihood: summary.metrics.residualEchoLikelihood,
                frameCount: result.result.frameCount,
                checksum: result.result.sha256,
                failure: nil,
                microphoneLeadFrames: Int((microphoneLeadSeconds * 48_000).rounded()),
                windows: report.0,
                windowRejections: report.1
            )
        } catch let error as MixdownError {
            // A failed job is a documented outcome, not a harness crash: the run
            // reports it and the scorer decides whether this case was allowed to
            // fail. The originals are still in the session directory.
            if !cleaned.isEmpty { try? WAVAudio(sampleRate: 48_000, channels: [cleaned]).write(to: cleanedURL) }
            let report = ((try? MixdownService().estimateEchoPath(sessionDirectory: sessionDirectory, options: options)).map(windowReport)) ?? ([], [])
            return Result(
                caseID: caseID, sessionDirectory: sessionDirectory,
                cleanedMicrophoneURL: cleanedURL, finalMixURL: finalMixURL, finalFLACURL: finalFLACURL,
                decision: "failed", delaySamples: nil, delayCorrelation: nil, delayBasis: nil,
                delaySegments: 0, analysisWindows: 0, processingLatencyFrames: 0, reconvergenceSeconds: [],
                truePeakBeforeGainDbTP: nil, appliedPeakGain: 1, echoReturnLossEnhancementDb: nil,
                residualEchoLikelihood: nil, frameCount: 0, checksum: "",
                failure: error.description,
                microphoneLeadFrames: Int((microphoneLeadSeconds * 48_000).rounded()),
                windows: report.0,
                windowRejections: report.1
            )
        }
    }

    /// Decodes the published FLAC back to float WAV so the same metrics tool can
    /// read it. Decoding is also the cheapest possible check that it is a real,
    /// readable file rather than bytes that happen to be on disk.
    public static func decodeFLAC(at source: URL, to destination: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: file.fileFormat.channelCount, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw HarnessError.message("could not decode \(source.lastPathComponent)")
        }
        try file.read(into: buffer, frameCount: frames)
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        try WAVAudio(sampleRate: Int(file.fileFormat.sampleRate), channels: channels).write(to: destination)
    }

    private static func writeTrack(
        _ writer: CaptureArchiveWriter,
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

    /// The minimal manifest a session needs before processing can record into it.
    public static func writeManifest(at directory: URL) throws {
        let manifest = RecorderSessionManifest(
            sessionID: UUID(),
            appBuild: "timeline-harness",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            startedAt: Date(timeIntervalSince1970: 0),
            completionStatus: .complete,
            capture: CaptureMetadata(
                state: .complete,
                scope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
                microphone: AudioDeviceIdentity(uniqueID: "harness", name: "Harness Microphone")
            ),
            tracks: RecorderTrackCollection(),
            processing: ProcessingMetadata(state: .pending)
        )
        try AtomicReplaceFileWriter().write(manifest, to: directory.appendingPathComponent("metadata.json"))
    }
}
