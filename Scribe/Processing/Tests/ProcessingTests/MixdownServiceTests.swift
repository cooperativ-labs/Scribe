import AVFAudio
import FLACBridge
import Foundation
import ScribeAppCore
import Testing
@testable import Processing

private let mixOrigin = 207_492.667875

@Test func theMixIsPublishedAsFortyEightKilohertzMonoSixteenBitAndRecordedInTheManifest() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 0.4)

    let captureBefore = try directoryDigest(session.appendingPathComponent("capture"))
    let result = try MixdownService().run(sessionDirectory: session)

    #expect(result.result.sampleRate == 48_000)
    #expect(result.result.channelCount == 1)
    #expect(result.result.bitDepth == .bits16)
    #expect(result.result.frameCount == result.timeline.outputFrameCount)

    let decoded = try AVAudioFile(forReading: session.appendingPathComponent("final.flac"))
    #expect(decoded.fileFormat.sampleRate == 48_000)
    #expect(decoded.fileFormat.channelCount == 1)
    #expect(decoded.length == result.timeline.outputFrameCount)
    #expect(try FLACStreamInfo.read(from: result.result.url).bitsPerSample == 16)

    // The capture archive is the session's one irreplaceable thing.
    #expect(try directoryDigest(session.appendingPathComponent("capture")) == captureBefore)

    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: session.appendingPathComponent("metadata.json")))
    #expect(manifest.processing.state == .complete)
    #expect(manifest.tracks.finalTrack?.fileName == "final.flac")
    #expect(manifest.tracks.finalTrack?.checksum == result.result.sha256)
    #expect(manifest.tracks.finalTrack?.journalReference == "capture/timeline.jsonl")
    #expect(manifest.processing.dependencyVersions["webrtc-audio-processing"]?.isEmpty == false)
    #expect(manifest.processing.mixGains["system"] != nil)
    #expect(manifest.processing.mixGains["microphoneCentre"] != nil)
    #expect(manifest.processing.mixGains["peakControl"] != nil)
    // The DSP latency compensation is recorded as the negative shift it is.
    let microphoneDelay = manifest.processing.delayCorrections.first { $0.track == .microphone }
    #expect(microphoneDelay != nil)
    #expect((microphoneDelay?.delaySeconds ?? 1) <= 0)
    guard case .object(let mixdown)? = manifest.processing.configuration["mixdown"] else {
        Issue.record("the manifest carries no mixdown configuration")
        return
    }
    #expect(mixdown["blockFrames"] == .number(480))
    #expect(mixdown["gainControllerEnabled"] == .boolean(false))
    #expect(mixdown["noiseSuppressionEnabled"] == .boolean(false))
    #expect(mixdown["truePeakCeilingDbTP"] == .number(-1))
    #expect(mixdown["echoPathDecision"] != nil)
    #expect(mixdown["measuredProcessingLatencyFrames"] != nil)
}

@Test func rerunningProducesTheSameMixAndLeavesTheOriginalsAlone() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 0.4)

    // This is the same transaction the queue and `scribe-process` invoke. A
    // completed recording can therefore be processed again from capture/ rather
    // than trusting any interrupted scratch state from a prior attempt.
    let first = try SessionProcessor().run(sessionDirectory: session)
    let captureAfterFirst = try directoryDigest(session.appendingPathComponent("capture"))
    let second = try SessionProcessor().run(sessionDirectory: session)
    #expect(first.result.sha256 == second.result.sha256)
    #expect(try directoryDigest(session.appendingPathComponent("capture")) == captureAfterFirst)
}

@Test func conservativeFixedGainsKeepTheDirectlyEncodedMixUnderTheCeiling() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Loud on both sides and with no echo path. Fixed gains leave enough headroom
    // to encode directly without a session-length scratch and normalization pass.
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 1.0, echoGain: 0, level: 0.95)

    let result = try MixdownService().run(sessionDirectory: session)
    #expect(result.summary.appliedPeakGain == 1)
    #expect(result.summary.samplePeakBeforeGain <= 0.88 + 0.000_1)

    var meter = TruePeakMeter(channelCount: 1)
    meter.append(try decode(session.appendingPathComponent("final.flac")))
    meter.finish()
    let dbTP = try #require(meter.truePeakDbTP)
    #expect(dbTP <= -1 + 0.01, "published mix measured \(String(format: "%.3f", dbTP)) dBTP")
}

@Test func aSessionWithNothingToCancelStillPublishesItsMix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Playback and unrelated near-end speech: headphones, no echo path.
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 1, echoGain: 0)

    let result = try MixdownService().run(sessionDirectory: session)
    if case .cancel = result.summary.decision {
        Issue.record("a session with no echo path must not be cancelled")
    }
    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: session.appendingPathComponent("metadata.json")))
    #expect(manifest.processing.state == .complete)
    #expect(manifest.tracks.finalTrack != nil)
}

@Test func aFailedJobKeepsTheOriginalsAndDoesNotPublishADoubledMix() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 0.4)
    let captureBefore = try directoryDigest(session.appendingPathComponent("capture"))

    // Force the refusal: a session where the echo is evident but no plausible
    // delay can be established, because none is searched for.
    var options = MixdownService.Options()
    options.delayEstimator.minimumCorrelation = 2
    options.delayEstimator.agreementMinimumCorrelation = 2

    #expect(throws: MixdownError.self) {
        try MixdownService().run(sessionDirectory: session, options: options)
    }
    #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("final.flac").path))
    #expect(try directoryDigest(session.appendingPathComponent("capture")) == captureBefore)

    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: session.appendingPathComponent("metadata.json")))
    #expect(manifest.processing.state == .failed)
    #expect(manifest.tracks.finalTrack == nil)
    #expect(manifest.processing.errors.contains { $0.code == "mixdown.uncertain-delay" })

    // No scratch file survives a failure.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: session.path).filter { $0.hasSuffix(".f32") }
    #expect(leftovers.isEmpty, "left behind \(leftovers)")
}

@Test func aFailedRerunDoesNotUnpublishAValidFinalFile() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeEchoSession(root: root, seconds: 2.5, delay: 1_440, nearEndGain: 0.4)
    let good = try MixdownService().run(sessionDirectory: session)

    var options = MixdownService.Options()
    options.delayEstimator.minimumCorrelation = 2
    options.delayEstimator.agreementMinimumCorrelation = 2
    #expect(throws: MixdownError.self) {
        try MixdownService().run(sessionDirectory: session, options: options)
    }

    #expect(try FLACEncoder.sha256(ofFileAt: session.appendingPathComponent("final.flac")) == good.result.sha256)
    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: session.appendingPathComponent("metadata.json")))
    #expect(manifest.processing.state == .failed)
    // The file is still on disk and still described, so a reader can see both the
    // valid result and the fact that the latest attempt failed.
    #expect(manifest.tracks.finalTrack?.checksum == good.result.sha256)
}

@Test func gapsAndRouteChangesBecomeReconvergencePoints() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try makeEchoSession(root: root, seconds: 4, delay: 1_440, nearEndGain: 0.4, microphoneGapAt: 2.0)

    let result = try MixdownService().run(sessionDirectory: session)
    let seconds = result.summary.reconvergences.map { ($0.seconds * 100).rounded() / 100 }
    #expect(seconds.contains(2.25), "reconvergence points: \(seconds)")
    #expect(result.summary.reconvergences.contains { $0.reason.contains("gap") })
}

// MARK: - Session construction

/// Writes a capture archive whose microphone is the system track through a known
/// echo path, plus an independent near-end signal.
private func makeEchoSession(
    root: URL,
    seconds: Double,
    delay: Int,
    nearEndGain: Float = 0,
    echoGain: Float = 0.6,
    level: Float = 1,
    microphoneGapAt gapStart: Double? = nil
) throws -> URL {
    let frames = Int(seconds * Double(timelineSampleRate))
    let reference = mixTestSignal(frames: frames, seed: 0x51ED_270B, peak: level)
    let nearEnd = mixTestSignal(frames: frames, seed: 0x2545_F491, peak: level)
    var microphone = [Float](repeating: 0, count: frames)
    let taps: [(Int, Float)] = [(0, 0.65), (223, 0.31), (617, 0.17), (1_133, 0.09)]
    for index in 0..<frames {
        var value: Float = 0
        for (offset, gain) in taps {
            let source = index - delay - offset
            if source >= 0 { value += gain * reference[source] }
        }
        microphone[index] = max(-1, min(1, value * echoGain + nearEnd[index] * nearEndGain))
    }

    let archive = try CaptureArchiveFixture(root: root)
    let block = 480
    var frame = 0
    while frame < frames {
        let count = min(block, frames - frame)
        let seconds = Double(frame) / Double(timelineSampleRate)
        try archive.write(
            track: "system", at: mixOrigin + seconds,
            samples: Array(reference[frame..<(frame + count)]),
            format: CaptureArchiveFixture.Format(sampleRate: 48_000, channelCount: 1)
        )
        // A journaled gap: the samples are simply absent and the timestamp jumps.
        if let gapStart, seconds >= gapStart, seconds < gapStart + 0.25 {
            frame += count
            continue
        }
        try archive.write(
            track: "microphone", at: mixOrigin + seconds,
            samples: Array(microphone[frame..<(frame + count)]),
            format: CaptureArchiveFixture.Format(sampleRate: 48_000, channelCount: 1)
        )
        frame += count
    }
    try archive.finish()
    try writeMixManifest(at: archive.sessionDirectory)
    return archive.sessionDirectory
}

/// Noise-excited and envelope-shaped, genuinely independent between seeds, and
/// normalized so `peak` is the signal's actual peak rather than a scale factor
/// applied to an unknown one.
private func mixTestSignal(frames: Int, seed: UInt64, peak: Float = 1) -> [Float] {
    var state = seed | 1
    var lowPass: Float = 0
    let samples = (0..<frames).map { index -> Float in
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        let noise = Float(Int32(truncatingIfNeeded: Int64(bitPattern: state))) / Float(Int32.max)
        lowPass = lowPass * 0.7 + noise * 0.3
        let envelope = Float(max(0, sin(Double(index) / Double(timelineSampleRate) * 1.7 * .pi)))
        return lowPass * envelope
    }
    let maximum = samples.reduce(Float(0)) { max($0, abs($1)) }
    guard maximum > 0 else { return samples }
    let scale = peak / maximum
    return samples.map { $0 * scale }
}

private func writeMixManifest(at directory: URL) throws {
    let manifest = RecorderSessionManifest(
        sessionID: UUID(),
        appBuild: "tests",
        macOSVersion: "tests",
        startedAt: Date(timeIntervalSince1970: 0),
        completionStatus: .complete,
        capture: CaptureMetadata(
            state: .complete,
            scope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "test", name: "Test Microphone")
        ),
        tracks: RecorderTrackCollection(),
        processing: ProcessingMetadata(state: .pending)
    )
    try AtomicReplaceFileWriter().write(manifest, to: directory.appendingPathComponent("metadata.json"))
}

private func decode(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.fileFormat.sampleRate, channels: file.fileFormat.channelCount, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw MixdownError.invalidOutputFormat
    }
    try file.read(into: buffer, frameCount: frames)
    return (0..<Int(buffer.format.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }
}
