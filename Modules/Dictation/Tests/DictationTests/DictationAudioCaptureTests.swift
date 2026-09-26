@preconcurrency import AVFoundation
import XCTest
@testable import Dictation

final class DictationAudioCaptureTests: XCTestCase {
    func testPreviewSnapshotIsBoundedAndDoesNotConsumeFinalAudio() {
        let ring = AudioRing()
        let samples = (0..<(AudioRing.capacity + 10)).map(Float.init)
        samples.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(ring.snapshot(maxSamples: 4), Array(samples.suffix(4)))
        XCTAssertEqual(ring.snapshot(maxSamples: 0), [])
        XCTAssertEqual(ring.snapshot().count, AudioRing.capacity)
        XCTAssertEqual(ring.snapshot().first, 10)
        XCTAssertEqual(ring.snapshot(maxSamples: 4), Array(samples.suffix(4)))
    }

    @MainActor
    func testAudioTapConvertsOnBackgroundQueue() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] = 0.25
            }
        }

        let ring = AudioRing()
        // Creation happens on MainActor, just as it does when right Command
        // starts capture. AVFAudio invokes the returned block off that actor.
        let tap = try DictationAudioCapture.makeTap(inputFormat: format, ring: ring)
        let invocation = TapInvocation(tap: tap, buffer: buffer)
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "DictationTests.audioTap").async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                for _ in 0..<3 { invocation.call() }
                continuation.resume()
            }
        }

        let samples = ring.snapshot()
        // The resampler may retain a small filter tail between callbacks.
        XCTAssertGreaterThan(samples.count, 4_600)
        XCTAssertLessThanOrEqual(samples.count, 4_800)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.25, accuracy: 0.001)
        XCTAssertEqual(ring.rms(), 0.25, accuracy: 0.001)
    }
}

/// Models AVFAudio transferring its legacy callback and buffer to one serial
/// audio queue. Neither is accessed elsewhere while the invocation is running.
private struct TapInvocation: @unchecked Sendable {
    let tap: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer

    func call() {
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate))
    }
}
