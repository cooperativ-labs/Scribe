import AVFoundation
import CoreMedia
import Foundation
import ScribeAppCore
import Storage

/// Copies a `CMSampleBuffer`'s audio into owned, transcription-oriented storage.
///
/// Everything here runs on a sample-handler queue, so it does only three things:
/// validate the buffer, copy its samples out, and describe its format. The
/// retained block buffer is released before this type returns, so **no no-copy
/// audio pointer ever outlives its backing sample buffer** -- the rule
/// IMPLEMENTATION_PLAN.md section 2 states, and the reason nothing downstream is
/// handed a `CMSampleBuffer`.
///
/// ScreenCaptureKit normally supplies float32 with anywhere from one to three
/// channels. Speech recognition consumes mono 16-bit audio, so float32 input is
/// downmixed and quantized while it is copied. This cuts the durable capture from
/// 4 bytes per source channel to 2 bytes per frame without changing timestamps or
/// sample rate. Unknown integer layouts are still retained losslessly.
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
        let archived = transcriptionArchive(samples: samples, format: format, frameCount: frameCount)

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentation.isValid, presentation.timescale != 0 else { return nil }
        // Rational arithmetic on the CMTime rather than CMTimeGetSeconds, so the
        // value keeps the timescale's precision over a multi-hour uptime clock.
        let seconds = Double(presentation.value) / Double(presentation.timescale)

        return try? OwnedPCMBuffer(
            track: track,
            presentationTimestampSeconds: seconds,
            format: archived.format,
            frameCount: frameCount,
            samples: archived.samples
        )
    }

    private static func transcriptionArchive(samples: Data, format: PCMFormat, frameCount: Int) -> (format: PCMFormat, samples: Data) {
        guard format.isFloat, format.bitsPerChannel == 32 else { return (format, samples) }
        let outputFormat = PCMFormat(sampleRate: format.sampleRate, channelCount: 1, bitsPerChannel: 16, isFloat: false)
        var output = [Int16](repeating: 0, count: frameCount)
        samples.withUnsafeBytes { raw in
            let input = raw.bindMemory(to: Float.self)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<format.channelCount {
                    sum += input[frame * format.channelCount + channel]
                }
                let mono = min(1, max(-1, sum / Float(format.channelCount)))
                output[frame] = Int16((mono * Float(Int16.max)).rounded())
            }
        }
        return (outputFormat, output.withUnsafeBufferPointer { Data(buffer: $0) })
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
