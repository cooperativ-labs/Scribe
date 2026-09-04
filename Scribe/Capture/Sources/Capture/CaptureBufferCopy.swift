import AVFoundation
import CoreMedia
import Foundation
import ScribeAppCore
import Storage

/// Copies a `CMSampleBuffer`'s audio into owned, interleaved storage.
///
/// Everything here runs on a sample-handler queue, so it does only three things:
/// validate the buffer, copy its samples out, and describe its format. The
/// retained block buffer is released before this type returns, so **no no-copy
/// audio pointer ever outlives its backing sample buffer** -- the rule
/// IMPLEMENTATION_PLAN.md section 2 states, and the reason nothing downstream is
/// handed a `CMSampleBuffer`.
///
/// Interleaving happens here rather than later because the two tracks do not agree:
/// system audio was measured arriving as 48 kHz stereo float32 **non-interleaved**
/// at 960 frames, while the microphone on the same stream arrived as 48 kHz mono
/// **interleaved** at 512 frames. `SessionStore` archives packed interleaved CAF, so
/// byte counts recover unambiguously after a crash.
public enum CaptureBufferCopy {
    /// Reads the buffer's own format description. Every buffer is inspected; the
    /// stream's requested configuration is never assumed to be what arrived.
    public static func inspectFormat(_ sampleBuffer: CMSampleBuffer) -> PCMFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        return format(from: asbd)
    }

    static func format(from asbd: AudioStreamBasicDescription) -> PCMFormat? {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBitsPerChannel > 0,
              asbd.mBitsPerChannel.isMultiple(of: 8) else { return nil }
        return PCMFormat(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        )
    }

    /// Copies `sampleBuffer` into an `OwnedPCMBuffer`, interleaving if the source is
    /// planar. Returns `nil` for anything that cannot be interpreted as linear PCM,
    /// which the caller counts rather than treating as fatal.
    public static func ownedBuffer(from sampleBuffer: CMSampleBuffer, track: RecorderTrackKind) -> OwnedPCMBuffer? {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = format(from: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bufferCount = isInterleaved ? 1 : format.channelCount
        let listSize = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(list.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list.unsafeMutablePointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        // `blockBuffer` owns the memory the list points at. Holding it until the
        // copy below finishes is what keeps those pointers valid; it is released
        // when this function returns, along with every pointer derived from it.
        guard status == noErr, blockBuffer != nil, list.count == bufferCount else { return nil }

        guard let samples = interleavedSamples(from: list, format: format, frameCount: frameCount, sourceIsInterleaved: isInterleaved) else { return nil }

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isValid, presentation.timescale != 0 else { return nil }
        // Rational arithmetic on the CMTime rather than CMTimeGetSeconds, so the
        // value keeps the timescale's precision over a multi-hour uptime clock.
        let seconds = Double(presentation.value) / Double(presentation.timescale)

        return try? OwnedPCMBuffer(
            track: track,
            presentationTimestampSeconds: seconds,
            format: format,
            frameCount: frameCount,
            samples: samples
        )
    }

    private static func interleavedSamples(
        from list: UnsafeMutableAudioBufferListPointer,
        format: PCMFormat,
        frameCount: Int,
        sourceIsInterleaved: Bool
    ) -> Data? {
        let expectedBytes = frameCount * format.bytesPerFrame
        if sourceIsInterleaved {
            guard let source = list[0].mData, Int(list[0].mDataByteSize) >= expectedBytes else { return nil }
            return Data(bytes: source, count: expectedBytes)
        }

        let bytesPerSample = format.bytesPerSample
        let planeBytes = frameCount * bytesPerSample
        for plane in 0..<format.channelCount {
            guard list[plane].mData != nil, Int(list[plane].mDataByteSize) >= planeBytes else { return nil }
        }

        var interleaved = Data(count: expectedBytes)
        interleaved.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for plane in 0..<format.channelCount {
                guard let source = list[plane].mData else { continue }
                for frame in 0..<frameCount {
                    memcpy(
                        base.advanced(by: (frame * format.channelCount + plane) * bytesPerSample),
                        source.advanced(by: frame * bytesPerSample),
                        bytesPerSample
                    )
                }
            }
        }
        return interleaved
    }
}
