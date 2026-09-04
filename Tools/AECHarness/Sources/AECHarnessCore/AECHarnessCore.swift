import Foundation
import WebRTCBridge

public enum AECHarnessError: Error, CustomStringConvertible {
    case invalidInput(String)
    case wav(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidInput(let message), .wav(let message), .io(let message): return message
        }
    }
}

/// A WAV reader whose working set is one block. It deliberately supports only
/// PCM and IEEE float variants that can be represented exactly enough as Float.
public final class StreamingWAVReader {
    public let url: URL
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int
    public let bitsPerSample: Int

    private let handle: FileHandle
    private let formatCode: Int
    private let bytesPerFrame: Int
    private let dataOffset: UInt64
    private let dataBytes: UInt64
    private var framesRead = 0

    public init(url: URL) throws {
        self.url = url
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw AECHarnessError.io("Cannot open \(url.path): \(error.localizedDescription)") }
        do {
            let fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            guard try Self.readString(handle, count: 4) == "RIFF" else {
                throw AECHarnessError.wav("\(url.lastPathComponent) is not a RIFF/WAVE file")
            }
            _ = try Self.readExact(handle, count: 4) // RIFF size
            guard try Self.readString(handle, count: 4) == "WAVE" else {
                throw AECHarnessError.wav("\(url.lastPathComponent) is not a WAVE file")
            }

            var parsedFormat: (code: Int, channels: Int, sampleRate: Int, bits: Int)?
            var parsedData: (offset: UInt64, bytes: UInt64)?
            while try handle.offset() + 8 <= fileSize {
                let identifier = try Self.readString(handle, count: 4)
                let declared = Int(try Self.readUInt32(handle))
                let payloadOffset = try handle.offset()
                let remaining = fileSize - payloadOffset
                guard UInt64(declared) <= remaining else {
                    throw AECHarnessError.wav("\(url.lastPathComponent) has a truncated \(identifier) chunk")
                }
                if identifier == "fmt " {
                    guard declared >= 16 else { throw AECHarnessError.wav("\(url.lastPathComponent) has a short fmt chunk") }
                    let bytes = try Self.readExact(handle, count: declared)
                    var code = Int(Self.uint16(bytes, 0))
                    if code == 0xFFFE, bytes.count >= 40 { code = Int(Self.uint16(bytes, 24)) }
                    parsedFormat = (code, Int(Self.uint16(bytes, 2)), Int(Self.uint32(bytes, 4)), Int(Self.uint16(bytes, 14)))
                } else if identifier == "data" {
                    parsedData = (payloadOffset, UInt64(declared))
                    try handle.seek(toOffset: payloadOffset + UInt64(declared))
                } else {
                    try handle.seek(toOffset: payloadOffset + UInt64(declared))
                }
                if declared % 2 == 1, try handle.offset() < fileSize { try handle.seek(toOffset: try handle.offset() + 1) }
            }
            guard let format = parsedFormat, let data = parsedData else {
                throw AECHarnessError.wav("\(url.lastPathComponent) needs both fmt and data chunks")
            }
            guard format.channels > 0, format.sampleRate > 0 else { throw AECHarnessError.wav("\(url.lastPathComponent) has invalid channel count or sample rate") }
            guard Self.supports(code: format.code, bits: format.bits) else {
                throw AECHarnessError.wav("\(url.lastPathComponent) uses unsupported WAV format \(format.code), \(format.bits)-bit")
            }
            let sampleBytes = format.bits / 8
            let stride = sampleBytes * format.channels
            guard stride > 0 else { throw AECHarnessError.wav("\(url.lastPathComponent) has invalid frame size") }
            self.formatCode = format.code
            self.channelCount = format.channels
            self.sampleRate = format.sampleRate
            self.bitsPerSample = format.bits
            self.bytesPerFrame = stride
            self.dataOffset = data.offset
            self.dataBytes = data.bytes - data.bytes % UInt64(stride)
            self.frameCount = Int(self.dataBytes / UInt64(stride))
            try handle.seek(toOffset: dataOffset)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    /// Reads no more than `requestedFrames`; callers pad only their final DSP block.
    public func read(frames requestedFrames: Int) throws -> [[Float]] {
        guard requestedFrames >= 0 else { throw AECHarnessError.invalidInput("Frame request must be non-negative") }
        let count = min(requestedFrames, frameCount - framesRead)
        guard count > 0 else { return Array(repeating: [], count: channelCount) }
        let bytes = try Self.readExact(handle, count: count * bytesPerFrame)
        var result = Array(repeating: Array(repeating: Float.zero, count: count), count: channelCount)
        let sampleBytes = bitsPerSample / 8
        for frame in 0..<count {
            for channel in 0..<channelCount {
                result[channel][frame] = Self.decode(bytes, at: frame * bytesPerFrame + channel * sampleBytes, code: formatCode, bits: bitsPerSample)
            }
        }
        framesRead += count
        return result
    }

    private static func supports(code: Int, bits: Int) -> Bool {
        [(1, 8), (1, 16), (1, 24), (1, 32), (3, 32)].contains { $0.0 == code && $0.1 == bits }
    }

    private static func decode(_ data: Data, at offset: Int, code: Int, bits: Int) -> Float {
        switch (code, bits) {
        case (1, 8): return (Float(data[offset]) - 128) / 128
        case (1, 16): return Float(Int16(bitPattern: uint16(data, offset))) / 32768
        case (1, 24):
            let raw = Int32(data[offset]) | Int32(data[offset + 1]) << 8 | Int32(data[offset + 2]) << 16
            return Float(raw & 0x80_0000 == 0 ? raw : raw - 0x100_0000) / 8_388_608
        case (1, 32): return Float(Int32(bitPattern: uint32(data, offset))) / 2_147_483_648
        case (3, 32): return Float(bitPattern: uint32(data, offset))
        default: return 0
        }
    }

    private static func readExact(_ handle: FileHandle, count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else { throw AECHarnessError.wav("Unexpected end of WAV file") }
        return data
    }
    private static func readString(_ handle: FileHandle, count: Int) throws -> String { String(decoding: try readExact(handle, count: count), as: UTF8.self) }
    private static func readUInt32(_ handle: FileHandle) throws -> UInt32 { uint32(try readExact(handle, count: 4), 0) }
    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24 }
}

public final class StreamingWAVWriter {
    public let destination: URL
    private let temporaryURL: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private let channelCount: Int
    private var dataBytes: UInt64 = 0

    public init(url: URL, sampleRate: Int, channelCount: Int) throws {
        guard sampleRate > 0, channelCount > 0 else { throw AECHarnessError.invalidInput("Output WAV needs a positive rate and channel count") }
        destination = url
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil), let handle = FileHandle(forWritingAtPath: temporaryURL.path) else {
            throw AECHarnessError.io("Cannot create \(temporaryURL.path)")
        }
        self.handle = handle
        try writeHeader(dataBytes: 0)
    }

    deinit { try? handle.close() }

    public func write(channels: [[Float]], frames: Int) throws {
        guard channels.count == channelCount, channels.allSatisfy({ $0.count >= frames }), frames >= 0 else {
            throw AECHarnessError.invalidInput("Output block channel layout does not match WAV writer")
        }
        let bytes = frames * channelCount * 2
        guard dataBytes + UInt64(bytes) <= UInt64(UInt32.max) - 36 else { throw AECHarnessError.io("WAV output exceeds RIFF's 4 GB limit") }
        var data = Data(capacity: bytes)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let clamped = max(-1, min(1, channels[channel][frame]))
                let sample = clamped <= -1 ? Int16.min : Int16((clamped * 32767).rounded())
                var le = UInt16(bitPattern: sample).littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        }
        try handle.write(contentsOf: data)
        dataBytes += UInt64(bytes)
    }

    public func finish() throws {
        try handle.seek(toOffset: 0)
        try writeHeader(dataBytes: dataBytes)
        try handle.close()
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try manager.moveItem(at: temporaryURL, to: destination)
        }
    }

    private func writeHeader(dataBytes: UInt64) throws {
        guard dataBytes <= UInt64(UInt32.max) - 36 else { throw AECHarnessError.io("WAV output exceeds RIFF's 4 GB limit") }
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataBytes), to: &data)
        data.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(channelCount), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * channelCount * 2), to: &data)
        append(UInt16(channelCount * 2), to: &data)
        append(UInt16(16), to: &data)
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataBytes), to: &data)
        try handle.write(contentsOf: data)
    }
    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
}

public enum BlockSchedule: String, Codable, Sendable {
    /// Required by AEC3: the far-end block is analyzed immediately before its capture block.
    case renderThenCapture = "render,capture"

    public init(argument: String) throws {
        guard argument.replacingOccurrences(of: " ", with: "") == Self.renderThenCapture.rawValue else {
            throw AECHarnessError.invalidInput("--block-schedule must be render,capture; AEC3 requires render analysis before each capture block")
        }
        self = .renderThenCapture
    }
}

public struct AECHarnessOptions: Sendable {
    public var referenceURL: URL
    public var microphoneURL: URL
    public var outputURL: URL
    public var reportURL: URL
    /// An acoustic, reconstructed-timeline delay; never timing measured around a DSP call.
    /// A supplied acoustic delay overrides estimation. `nil` asks for a correlated
    /// far-end-only calibration pass before AEC starts.
    public var renderToCaptureDelaySamples: Int?
    /// Reconstructed-timeline positions at which capture metadata documents a gap,
    /// route change, or other discontinuity. Each causes an AEC3 reset before its block.
    public var discontinuitySamples: [Int]
    public var blockSchedule: BlockSchedule

    public init(referenceURL: URL, microphoneURL: URL, outputURL: URL, reportURL: URL, renderToCaptureDelaySamples: Int? = nil, discontinuitySamples: [Int] = [], blockSchedule: BlockSchedule = .renderThenCapture) {
        self.referenceURL = referenceURL
        self.microphoneURL = microphoneURL
        self.outputURL = outputURL
        self.reportURL = reportURL
        self.renderToCaptureDelaySamples = renderToCaptureDelaySamples
        self.discontinuitySamples = discontinuitySamples
        self.blockSchedule = blockSchedule
    }
}

private struct ReportInput: Codable {
    let referenceFile: String; let microphoneFile: String; let referenceChannels: Int; let microphoneChannels: Int
    let referenceFrames: Int; let microphoneFrames: Int; let sampleRate: Int; let blockFrames: Int; let blockSchedule: BlockSchedule
    let declaredRenderToCaptureDelaySamples: Int?; let documentedDiscontinuitySamples: [Int]; let appliedStreamDelayMilliseconds: Int?; let streamDelayQuantizationErrorSamples: Int?
}
private struct DelayDecision: Codable {
    let source: String; let estimate: DelayEstimate?; let rejection: DelayEstimationRejection?; let appliedDelaySamples: Int?; let appliedDelayMilliseconds: Int?
}
private struct ReconvergenceEvent: Codable {
    let startSample: Int; let previousDelaySamples: Int; let newDelaySamples: Int; let reason: String
}
private struct AECMetric: Codable {
    let echoReturnLossDb: Double?; let reportedERLEDb: Double?; let delayMilliseconds: Int32?; let medianDelayMilliseconds: Int32?
    let delayStandardDeviationMilliseconds: Int32?; let divergentFilterFraction: Double?; let residualEchoLikelihood: Double?
}
private struct BlockMetric: Codable {
    let index: Int; let startSample: Int; let inputEnergy: Double; let outputEnergy: Double; let erleDb: Double?; let aec3: AECMetric
}
private struct ReportSummary: Codable {
    let processedFrames: Int; let blocks: Int; let convergenceTimeSeconds: Double?; let convergenceDefinition: String
    let measuredReductionDbAfterConvergence: Double?; let maximumWorkingAudioSamples: Int; let outputFile: String
    let delayDecision: DelayDecision; let reconvergenceEvents: [ReconvergenceEvent]; let processingStatus: String
}

/// Runs the bridge without accumulating input or output audio in memory. The report is likewise
/// written block-by-block, so only a single 10 ms DSP block and one encoded metric are live.
public enum AECHarnessRunner {
    public static let sampleRate = 48_000
    public static let blockFrames = 480

    @discardableResult
    public static func run(_ options: AECHarnessOptions) throws -> URL {
        guard (options.renderToCaptureDelaySamples ?? 0) >= 0 else { throw AECHarnessError.invalidInput("--delay-samples must be zero or positive") }
        let reference = try StreamingWAVReader(url: options.referenceURL)
        let microphone = try StreamingWAVReader(url: options.microphoneURL)
        guard reference.sampleRate == sampleRate, microphone.sampleRate == sampleRate else {
            throw AECHarnessError.invalidInput("Both inputs must be 48 kHz; resample into a reconstructed 48 kHz timeline before running AEC")
        }
        guard (1...2).contains(reference.channelCount) else { throw AECHarnessError.invalidInput("Reference WAV must have one or two channels") }
        guard microphone.channelCount == 1 else { throw AECHarnessError.invalidInput("Microphone WAV must be mono for this initial bridge configuration") }

        let calibration = try initialDelayDecision(referenceURL: options.referenceURL, microphoneURL: options.microphoneURL, fixedDelay: options.renderToCaptureDelaySamples)
        guard let activeDelaySamples = calibration.appliedDelaySamples, let delayMilliseconds = calibration.appliedDelayMilliseconds else {
            return try bypassUncertainDelay(options: options, microphone: microphone, reference: reference, decision: calibration)
        }
        var configuration = EchoCanceller.Configuration.scribeDefault
        configuration.renderChannelCount = 2
        configuration.captureChannelCount = 1
        let canceller = try EchoCanceller(configuration: configuration)
        try canceller.setStreamDelay(milliseconds: Int32(delayMilliseconds))
        let output = try StreamingWAVWriter(url: options.outputURL, sampleRate: sampleRate, channelCount: 1)
        let report = try IncrementalReportWriter(url: options.reportURL)
        try report.begin(input: ReportInput(referenceFile: options.referenceURL.path, microphoneFile: options.microphoneURL.path, referenceChannels: reference.channelCount, microphoneChannels: microphone.channelCount, referenceFrames: reference.frameCount, microphoneFrames: microphone.frameCount, sampleRate: sampleRate, blockFrames: blockFrames, blockSchedule: options.blockSchedule, declaredRenderToCaptureDelaySamples: options.renderToCaptureDelaySamples, documentedDiscontinuitySamples: options.discontinuitySamples.sorted(), appliedStreamDelayMilliseconds: delayMilliseconds, streamDelayQuantizationErrorSamples: activeDelaySamples - (options.renderToCaptureDelaySamples ?? activeDelaySamples)))

        var blockIndex = 0
        var goodBlocks = 0
        var convergenceBlock: Int?
        var postConvergenceInputEnergy = 0.0
        var postConvergenceOutputEnergy = 0.0
        var rollingEstimator = DelayEstimator()
        var currentDelaySamples = activeDelaySamples
        var reconvergenceEvents: [ReconvergenceEvent] = []
        var pendingDiscontinuities = options.discontinuitySamples.filter { $0 >= 0 }.sorted()
        while true {
            let microphoneBlock = try microphone.read(frames: blockFrames)
            let availableFrames = microphoneBlock.first?.count ?? 0
            guard availableFrames > 0 else { break }
            var referenceBlock = try reference.read(frames: blockFrames)
            if referenceBlock.first?.count ?? 0 < blockFrames { referenceBlock = padded(referenceBlock, channels: reference.channelCount, frames: blockFrames) }
            if reference.channelCount == 1 { referenceBlock.append(referenceBlock[0]) }
            let paddedMicrophone = padded(microphoneBlock, channels: 1, frames: blockFrames)
            while let discontinuity = pendingDiscontinuities.first, discontinuity <= blockIndex * blockFrames {
                try canceller.reset()
                reconvergenceEvents.append(.init(startSample: blockIndex * blockFrames, previousDelaySamples: currentDelaySamples, newDelaySamples: currentDelaySamples, reason: "documented input timeline discontinuity at sample \(discontinuity)"))
                pendingDiscontinuities.removeFirst()
                goodBlocks = 0
                convergenceBlock = nil
                postConvergenceInputEnergy = 0
                postConvergenceOutputEnergy = 0
            }
            rollingEstimator.append(render: referenceBlock[0], capture: paddedMicrophone[0])
            if blockIndex > 0, blockIndex % 100 == 0, case .success(let estimate) = rollingEstimator.estimate(), abs(estimate.delaySamples - currentDelaySamples) >= blockFrames {
                try canceller.reset()
                let newDelayMilliseconds = Int((Double(estimate.delaySamples) * 1_000 / Double(sampleRate)).rounded())
                try canceller.setStreamDelay(milliseconds: Int32(newDelayMilliseconds))
                reconvergenceEvents.append(.init(startSample: blockIndex * blockFrames, previousDelaySamples: currentDelaySamples, newDelaySamples: estimate.delaySamples, reason: "a confident correlated delay estimate changed by at least one 10 ms block"))
                currentDelaySamples = estimate.delaySamples
                goodBlocks = 0
                convergenceBlock = nil
                postConvergenceInputEnergy = 0
                postConvergenceOutputEnergy = 0
            }
            let render = PlanarAudioBlock(channels: referenceBlock)
            let capture = PlanarAudioBlock(channels: paddedMicrophone)
            var cleaned = PlanarAudioBlock(channelCount: 1, frameCount: blockFrames)
            try canceller.analyzeRenderBlock(render)
            try canceller.processCaptureBlock(capture, into: &cleaned)
            let cleanChannel = Array(cleaned[channel: 0])
            try output.write(channels: [cleanChannel], frames: availableFrames)

            let inputEnergy = energy(paddedMicrophone[0], count: availableFrames)
            let outputEnergy = energy(cleanChannel, count: availableFrames)
            let erle = inputEnergy > 1e-12 ? 10 * log10(inputEnergy / max(outputEnergy, Double.leastNormalMagnitude)) : nil
            if let erle, inputEnergy > 1e-8, erle >= 10 {
                goodBlocks += 1
                if goodBlocks >= 10, convergenceBlock == nil { convergenceBlock = blockIndex - 9 }
            } else { goodBlocks = 0 }
            if convergenceBlock != nil { postConvergenceInputEnergy += inputEnergy; postConvergenceOutputEnergy += outputEnergy }
            let metrics = canceller.metrics()
            try report.append(BlockMetric(index: blockIndex, startSample: blockIndex * blockFrames, inputEnergy: inputEnergy, outputEnergy: outputEnergy, erleDb: erle, aec3: AECMetric(echoReturnLossDb: metrics.echoReturnLoss, reportedERLEDb: metrics.echoReturnLossEnhancement, delayMilliseconds: metrics.delayMilliseconds, medianDelayMilliseconds: metrics.medianDelayMilliseconds, delayStandardDeviationMilliseconds: metrics.delayStandardDeviationMilliseconds, divergentFilterFraction: metrics.divergentFilterFraction, residualEchoLikelihood: metrics.residualEchoLikelihood)))
            blockIndex += 1
        }
        try output.finish()
        let reduction = postConvergenceInputEnergy > 0 ? 10 * log10(postConvergenceInputEnergy / max(postConvergenceOutputEnergy, Double.leastNormalMagnitude)) : nil
        // At most eight 480-sample channel buffers coexist: input/reference
        // reads, padded blocks, the bridge-owned planar copies, and output.
        try report.finish(summary: ReportSummary(processedFrames: microphone.frameCount, blocks: blockIndex, convergenceTimeSeconds: convergenceBlock.map { Double($0 * blockFrames) / Double(sampleRate) }, convergenceDefinition: "first 10 consecutive active 10 ms blocks with input-to-output energy reduction of at least 10 dB after the latest reset; harness ERLE is independently computed and not AEC3's windowed statistic", measuredReductionDbAfterConvergence: reduction, maximumWorkingAudioSamples: max(blockFrames * 8, DelayEstimator.analysisFrames * 2 + DelayEstimator.maximumDelaySamples * 2), outputFile: options.outputURL.path, delayDecision: calibration, reconvergenceEvents: reconvergenceEvents, processingStatus: "processed"))
        return options.outputURL
    }

    private static func initialDelayDecision(referenceURL: URL, microphoneURL: URL, fixedDelay: Int?) throws -> DelayDecision {
        if let fixedDelay {
            let milliseconds = Int((Double(fixedDelay) * 1_000 / Double(sampleRate)).rounded())
            return .init(source: "fixed", estimate: nil, rejection: nil, appliedDelaySamples: milliseconds * sampleRate / 1_000, appliedDelayMilliseconds: milliseconds)
        }
        let reference = try StreamingWAVReader(url: referenceURL)
        let microphone = try StreamingWAVReader(url: microphoneURL)
        var estimator = DelayEstimator()
        while !estimator.hasAnalysisWindow {
            let render = try reference.read(frames: blockFrames)
            let capture = try microphone.read(frames: blockFrames)
            guard let renderChannel = render.first, let captureChannel = capture.first, !renderChannel.isEmpty, !captureChannel.isEmpty else { break }
            estimator.append(render: renderChannel, capture: captureChannel)
        }
        switch estimator.estimate() {
        case .success(let estimate):
            let milliseconds = Int((Double(estimate.delaySamples) * 1_000 / Double(sampleRate)).rounded())
            return .init(source: "correlated-far-end-only", estimate: estimate, rejection: nil, appliedDelaySamples: milliseconds * sampleRate / 1_000, appliedDelayMilliseconds: milliseconds)
        case .failure(let rejection):
            // Do not invent a zero-delay AEC configuration. The caller gets a complete,
            // explicitly marked pass-through instead of an output that looks safely cleaned.
            return .init(source: "uncertain-bypass", estimate: nil, rejection: rejection, appliedDelaySamples: nil, appliedDelayMilliseconds: nil)
        }
    }

    private static func bypassUncertainDelay(options: AECHarnessOptions, microphone: StreamingWAVReader, reference: StreamingWAVReader, decision: DelayDecision) throws -> URL {
        let output = try StreamingWAVWriter(url: options.outputURL, sampleRate: sampleRate, channelCount: 1)
        let report = try IncrementalReportWriter(url: options.reportURL)
        try report.begin(input: .init(referenceFile: options.referenceURL.path, microphoneFile: options.microphoneURL.path, referenceChannels: reference.channelCount, microphoneChannels: microphone.channelCount, referenceFrames: reference.frameCount, microphoneFrames: microphone.frameCount, sampleRate: sampleRate, blockFrames: blockFrames, blockSchedule: options.blockSchedule, declaredRenderToCaptureDelaySamples: nil, documentedDiscontinuitySamples: options.discontinuitySamples.sorted(), appliedStreamDelayMilliseconds: nil, streamDelayQuantizationErrorSamples: nil))
        var blocks = 0
        while true {
            let input = try microphone.read(frames: blockFrames)
            guard let channel = input.first, !channel.isEmpty else { break }
            try output.write(channels: [channel], frames: channel.count)
            let inputEnergy = energy(channel, count: channel.count)
            try report.append(.init(index: blocks, startSample: blocks * blockFrames, inputEnergy: inputEnergy, outputEnergy: inputEnergy, erleDb: 0, aec3: .init(echoReturnLossDb: nil, reportedERLEDb: nil, delayMilliseconds: nil, medianDelayMilliseconds: nil, delayStandardDeviationMilliseconds: nil, divergentFilterFraction: nil, residualEchoLikelihood: nil)))
            blocks += 1
        }
        try output.finish()
        try report.finish(summary: .init(processedFrames: microphone.frameCount, blocks: blocks, convergenceTimeSeconds: nil, convergenceDefinition: "not evaluated: no confident delay estimate", measuredReductionDbAfterConvergence: nil, maximumWorkingAudioSamples: blockFrames * 2 + DelayEstimator.analysisFrames * 2 + DelayEstimator.maximumDelaySamples * 2, outputFile: options.outputURL.path, delayDecision: decision, reconvergenceEvents: [], processingStatus: "uncertain-delay-bypass"))
        return options.outputURL
    }

    private static func padded(_ channels: [[Float]], channels count: Int, frames: Int) -> [[Float]] {
        (0..<count).map { channel in
            var result = channel < channels.count ? channels[channel] : []
            result.append(contentsOf: repeatElement(0, count: max(0, frames - result.count)))
            return result
        }
    }
    private static func energy(_ samples: [Float], count: Int) -> Double { samples.prefix(count).reduce(0) { $0 + Double($1) * Double($1) } }
}

private final class IncrementalReportWriter {
    private let temporaryURL: URL; private let destination: URL; private let handle: FileHandle; private var first = true
    init(url: URL) throws {
        destination = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil), let handle = FileHandle(forWritingAtPath: temporaryURL.path) else { throw AECHarnessError.io("Cannot create \(temporaryURL.path)") }
        self.handle = handle
    }
    deinit { try? handle.close() }
    func begin(input: ReportInput) throws { try write("{\"schemaVersion\":1,\"tool\":\"aec-harness\",\"input\":"); try writeJSON(input); try write(",\"blocks\":[") }
    func append(_ block: BlockMetric) throws { if !first { try write(",") }; first = false; try writeJSON(block) }
    func finish(summary: ReportSummary) throws {
        try write("],\"summary\":"); try writeJSON(summary); try write("}\n"); try handle.close()
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: temporaryURL) } else { try manager.moveItem(at: temporaryURL, to: destination) }
    }
    private func writeJSON<T: Encodable>(_ value: T) throws { try handle.write(contentsOf: JSONEncoder().encode(value)) }
    private func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
}
