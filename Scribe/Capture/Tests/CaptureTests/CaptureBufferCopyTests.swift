import AVFoundation
import CoreMedia
import Foundation
import ScribeAppCore
import Storage
import Testing
@testable import Capture

/// Builds real `CMSampleBuffer`s in both layouts ScreenCaptureKit was measured to
/// deliver, so the copy-out path is exercised without a capture permission:
/// system audio arrived 48 kHz stereo float32 **non-interleaved** at 960 frames,
/// while the microphone on the same stream arrived 48 kHz mono **interleaved** at
/// 512 frames.
enum SyntheticSampleBuffer {
    static func make(
        sampleRate: Double,
        channelCount: Int,
        interleaved: Bool,
        frameCount: Int,
        presentation: CMTime,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) throws -> CMSampleBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if interleaved {
            let data = buffer.floatChannelData![0]
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    data[frame * channelCount + channel] = sample(channel, frame)
                }
            }
        } else {
            for channel in 0..<channelCount {
                let plane = buffer.floatChannelData![channel]
                for frame in 0..<frameCount { plane[frame] = sample(channel, frame) }
            }
        }

        var formatDescription: CMFormatDescription?
        var asbd = format.streamDescription.pointee
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw SyntheticError.formatDescription
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentation,
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            throw SyntheticError.sampleBuffer
        }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else {
            throw SyntheticError.attachData
        }
        guard CMSampleBufferSetDataReady(sampleBuffer) == noErr else { throw SyntheticError.dataReady }
        return sampleBuffer
    }

    enum SyntheticError: Error { case formatDescription, sampleBuffer, attachData, dataReady }
}

@Suite struct CaptureBufferCopyTests {
    /// Non-interleaved stereo is what the `.audio` track actually delivers, and
    /// `SessionStore` archives packed interleaved CAF, so the plane-to-frame
    /// transposition has to be right or every recording is channel-scrambled.
    @Test func planarStereoIsCopiedOutInterleavedInFrameOrder() throws {
        let frames = 960
        let sampleBuffer = try SyntheticSampleBuffer.make(
            sampleRate: 48_000,
            channelCount: 2,
            interleaved: false,
            frameCount: frames,
            presentation: CMTime(value: 207_492_667_875, timescale: 1_000_000)
        ) { channel, frame in Float(channel) * 1_000 + Float(frame) }

        let owned = try #require(CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: .system))
        #expect(owned.track == .system)
        #expect(owned.frameCount == frames)
        #expect(owned.format == PCMFormat(sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isFloat: true))
        #expect(owned.samples.count == frames * 2 * 4)

        let values: [Float] = owned.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(values[0] == 0)          // frame 0, left
        #expect(values[1] == 1_000)      // frame 0, right
        #expect(values[2] == 1)          // frame 1, left
        #expect(values[3] == 1_001)      // frame 1, right
        #expect(values[2 * (frames - 1)] == Float(frames - 1))
        #expect(values[2 * (frames - 1) + 1] == Float(frames - 1) + 1_000)
    }

    @Test func interleavedMonoIsCopiedOutUnchanged() throws {
        let frames = 512
        let sampleBuffer = try SyntheticSampleBuffer.make(
            sampleRate: 48_000,
            channelCount: 1,
            interleaved: true,
            frameCount: frames,
            presentation: CMTime(value: 207_492_998_875, timescale: 1_000_000)
        ) { _, frame in Float(frame) / 512 }

        let owned = try #require(CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: .microphone))
        #expect(owned.format == PCMFormat(sampleRate: 48_000, channelCount: 1, bitsPerChannel: 32, isFloat: true))
        #expect(owned.frameCount == frames)

        let values: [Float] = owned.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(values.count == frames)
        #expect(values[0] == 0)
        #expect(values[511] == Float(511) / 512)
    }

    /// The timestamp is the whole timeline. Reading it as a rational value keeps
    /// the precision of a clock that is already past 200 000 seconds of uptime.
    @Test func presentationTimestampKeepsItsTimescalePrecision() throws {
        let sampleBuffer = try SyntheticSampleBuffer.make(
            sampleRate: 48_000,
            channelCount: 1,
            interleaved: true,
            frameCount: 8,
            presentation: CMTime(value: 9_959_648_058, timescale: 48_000)
        ) { _, _ in 0 }

        let owned = try #require(CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: .microphone))
        #expect(owned.presentationTimestampSeconds == 9_959_648_058.0 / 48_000.0)
    }

    /// Two tracks starting at different presentation timestamps is the normal case:
    /// the microphone was measured starting +0.123 s to +2.594 s after system audio,
    /// never simultaneously. Nothing here may normalize that away.
    @Test func eachTrackKeepsItsOwnFirstTimestamp() throws {
        let system = try SyntheticSampleBuffer.make(
            sampleRate: 48_000, channelCount: 2, interleaved: false, frameCount: 960,
            presentation: CMTime(value: 207_637_576_748, timescale: 1_000_000)
        ) { _, _ in 0 }
        let microphone = try SyntheticSampleBuffer.make(
            sampleRate: 48_000, channelCount: 1, interleaved: true, frameCount: 512,
            presentation: CMTime(value: 207_640_170_292, timescale: 1_000_000)
        ) { _, _ in 0 }

        let systemBuffer = try #require(CaptureBufferCopy.ownedBuffer(from: system, track: .system))
        let microphoneBuffer = try #require(CaptureBufferCopy.ownedBuffer(from: microphone, track: .microphone))
        let offset = microphoneBuffer.presentationTimestampSeconds - systemBuffer.presentationTimestampSeconds
        #expect(abs(offset - 2.593544) < 0.000_001)
    }

    /// Every buffer's own format description is read; the stream's requested
    /// 48 kHz stereo configuration is never assumed to be what arrived.
    @Test func formatIsInspectedPerBufferRatherThanAssumed() throws {
        let requestedStereo = try SyntheticSampleBuffer.make(
            sampleRate: 44_100, channelCount: 1, interleaved: true, frameCount: 256,
            presentation: CMTime(value: 1, timescale: 48_000)
        ) { _, _ in 0 }

        let inspected = try #require(CaptureBufferCopy.inspectFormat(requestedStereo))
        #expect(inspected == PCMFormat(sampleRate: 44_100, channelCount: 1, bitsPerChannel: 32, isFloat: true))
        #expect(inspected.description.contains("44100"))
    }

    @Test func nonLinearPCMIsRejectedRatherThanArchivedAsGarbage() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        #expect(CaptureBufferCopy.format(from: asbd) == nil)

        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 20 // not a whole number of bytes
        #expect(CaptureBufferCopy.format(from: asbd) == nil)
    }

    @Test func integerAndFloatFlagsAreReportedFromTheBufferItself() {
        let float = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        #expect(CaptureBufferCopy.format(from: float)?.isFloat == true)

        let integer = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        let resolved = CaptureBufferCopy.format(from: integer)
        #expect(resolved?.isFloat == false)
        #expect(resolved?.sampleRate == 16_000)
        #expect(resolved?.bytesPerFrame == 2)
    }

    /// The copied buffer must remain valid after the sample buffer it came from is
    /// gone. That is the entire point of copying rather than retaining.
    @Test func copiedSamplesOutliveTheSampleBuffer() throws {
        var owned: OwnedPCMBuffer?
        do {
            let sampleBuffer = try SyntheticSampleBuffer.make(
                sampleRate: 48_000, channelCount: 2, interleaved: false, frameCount: 64,
                presentation: CMTime(value: 5, timescale: 48_000)
            ) { channel, frame in Float(channel * 64 + frame) }
            owned = CaptureBufferCopy.ownedBuffer(from: sampleBuffer, track: .system)
        }
        let buffer = try #require(owned)
        let values: [Float] = buffer.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(values[0] == 0)
        #expect(values[1] == 64)
        #expect(values[126] == 63)
        #expect(values[127] == 127)
    }
}
