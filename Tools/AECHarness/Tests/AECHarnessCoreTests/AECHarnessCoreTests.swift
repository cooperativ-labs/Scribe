import Foundation
import Testing
@testable import AECHarnessCore

@Suite("Offline AEC harness")
struct AECHarnessCoreTests {
    @Test("Estimates delay only from a confident correlated region")
    func estimatesCorrelatedDelay() {
        let frames = DelayEstimator.analysisFrames + DelayEstimator.maximumDelaySamples
        let delay = 1_440
        var render = Array(repeating: Float.zero, count: frames)
        var capture = Array(repeating: Float.zero, count: frames)
        var state: UInt64 = 0x1357_9BDF_2468_ACE0
        for index in render.indices {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            render[index] = Float(Int32(truncatingIfNeeded: state &* 0x2545_F491_4F6C_DD1D >> 32)) / Float(Int32.max) * 0.25
            if index >= delay { capture[index] = render[index - delay] * 0.65 }
        }
        var estimator = DelayEstimator()
        for offset in stride(from: 0, to: frames, by: 480) {
            let end = min(frames, offset + 480)
            estimator.append(render: Array(render[offset..<end]), capture: Array(capture[offset..<end]))
        }
        guard case .success(let estimate) = estimator.estimate() else {
            Issue.record("Expected a confident estimate")
            return
        }
        #expect(abs(estimate.delaySamples - delay) <= 2)
        #expect(estimate.correlation >= DelayEstimator.minimumCorrelation)
    }

    @Test("Rejects silence and unrelated local speech as delay calibration")
    func rejectsUnsafeCalibration() {
        var silence = DelayEstimator()
        silence.append(render: Array(repeating: 0, count: DelayEstimator.analysisFrames), capture: Array(repeating: 0, count: DelayEstimator.analysisFrames))
        guard case .failure(let silenceRejection) = silence.estimate() else {
            Issue.record("Silence must not yield a delay")
            return
        }
        #expect(silenceRejection.reason.contains("silence"))

        var render = Array(repeating: Float.zero, count: DelayEstimator.analysisFrames)
        var local = Array(repeating: Float.zero, count: DelayEstimator.analysisFrames)
        var first: UInt64 = 0x1111_2222_3333_4444
        var second: UInt64 = 0xAAAA_BBBB_CCCC_DDDD
        for index in render.indices {
            first ^= first >> 12; first ^= first << 25; first ^= first >> 27
            second ^= second >> 12; second ^= second << 25; second ^= second >> 27
            render[index] = Float(Int32(truncatingIfNeeded: first &* 0x2545_F491_4F6C_DD1D >> 32)) / Float(Int32.max) * 0.2
            local[index] = Float(Int32(truncatingIfNeeded: second &* 0x2545_F491_4F6C_DD1D >> 32)) / Float(Int32.max) * 0.2
        }
        var estimator = DelayEstimator()
        estimator.append(render: render, capture: local)
        guard case .failure(let localRejection) = estimator.estimate() else {
            Issue.record("Unrelated local speech must not yield a delay")
            return
        }
        #expect(localRejection.reason.contains("local speech"))
    }

    @Test("Processes a delayed far-end-only timeline with measurable reduction")
    func processesSyntheticEcho() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aec-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let referenceURL = directory.appendingPathComponent("reference.wav")
        let microphoneURL = directory.appendingPathComponent("microphone.wav")
        let outputURL = directory.appendingPathComponent("cleaned.wav")
        let reportURL = directory.appendingPathComponent("metrics.json")
        let frames = 48_000 * 4; let delay = 1_440
        var reference = Array(repeating: Float.zero, count: frames)
        var microphone = Array(repeating: Float.zero, count: frames)
        var random: UInt64 = 0x5C21_BE00_1234_5678
        for index in 0..<frames {
            random ^= random >> 12; random ^= random << 25; random ^= random >> 27
            reference[index] = Float(Int32(truncatingIfNeeded: random &* 0x2545_F491_4F6C_DD1D >> 32)) / Float(Int32.max) * 0.2
            if index >= delay { microphone[index] = reference[index - delay] * 0.5 }
        }
        let refWriter = try StreamingWAVWriter(url: referenceURL, sampleRate: 48_000, channelCount: 1)
        try refWriter.write(channels: [reference], frames: frames); try refWriter.finish()
        let micWriter = try StreamingWAVWriter(url: microphoneURL, sampleRate: 48_000, channelCount: 1)
        try micWriter.write(channels: [microphone], frames: frames); try micWriter.finish()
        try AECHarnessRunner.run(AECHarnessOptions(referenceURL: referenceURL, microphoneURL: microphoneURL, outputURL: outputURL, reportURL: reportURL, renderToCaptureDelaySamples: delay))
        let cleaned = try StreamingWAVReader(url: outputURL)
        var inputEnergy = 0.0; var outputEnergy = 0.0; var outputFrame = 0
        while true {
            let block = try cleaned.read(frames: 480)
            guard let samples = block.first, !samples.isEmpty else { break }
            for sample in samples where outputFrame >= 48_000 { outputEnergy += Double(sample) * Double(sample) }
            outputFrame += samples.count
        }
        inputEnergy = microphone.dropFirst(48_000).reduce(0) { $0 + Double($1) * Double($1) }
        #expect(10 * log10(inputEnergy / max(outputEnergy, Double.leastNormalMagnitude)) > 10)
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        #expect(report.contains("\"blocks\"")); #expect(report.contains("\"convergenceTimeSeconds\""))
    }
}
