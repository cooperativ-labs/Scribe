import Foundation

private let canonicalSampleRate = 48_000
private let defaultDurationSeconds = 10.0
private let defaultSeed: UInt64 = 0x5C_71_BE_5E_D

private struct Options {
    var outputDirectory: URL
    var seed = defaultSeed
    var durationSeconds = defaultDurationSeconds

    static func parse() throws -> Options {
        var result = Options(outputDirectory: URL(fileURLWithPath: "Generated", isDirectory: true))
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else { throw GeneratorError.usage("--output needs a directory") }
                result.outputDirectory = URL(fileURLWithPath: value, isDirectory: true)
            case "--seed":
                guard let value = iterator.next(), let seed = parseSeed(value) else { throw GeneratorError.usage("--seed needs an unsigned integer or 0x hexadecimal value") }
                result.seed = seed
            case "--duration":
                guard let value = iterator.next(), let duration = Double(value), duration >= 10, duration <= 60 else {
                    throw GeneratorError.usage("--duration must be between 10 and 60 seconds")
                }
                result.durationSeconds = duration
            case "--help", "-h":
                throw GeneratorError.usage(nil)
            default:
                throw GeneratorError.usage("Unknown option: \(argument)")
            }
        }
        return result
    }

    private static func parseSeed(_ value: String) -> UInt64? {
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }
}

private enum GeneratorError: Error, CustomStringConvertible {
    case usage(String?)
    case invalidConfiguration(String)

    var description: String {
        switch self {
        case .usage(let reason):
            let prefix = reason.map { "\($0)\n\n" } ?? ""
            return prefix + "Usage: generate-audio-fixtures [--output DIRECTORY] [--seed UINT64] [--duration 10...60]"
        case .invalidConfiguration(let message):
            return message
        }
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) * (1.0 / Double(1 << 53))
    }
}

private struct Interval: Codable {
    let startSeconds: Double
    let endSeconds: Double
}

private struct DelaySegment: Codable {
    let startSeconds: Double
    let endSeconds: Double
    let delaySamples: Int
}

private struct Track: Codable {
    let file: String
    let sampleRate: Int
    let channels: Int
    let variant: String?
}

private struct FixtureSidecar: Codable {
    let schemaVersion: Int
    let caseID: String
    let description: String
    let seed: String
    let durationSeconds: Double
    let playback: Track
    let echo: Track
    let localSpeech: Track
    let microphone: Track
    let trueDelaySamples: Int
    let delaySegments: [DelaySegment]
    let reverbTaps: [Double]
    let driftRatio: Double
    let gapIntervals: [Interval]
    let nearEndRegions: [Interval]
}

private enum PlaybackVariant: String { case speechLike = "speech-like", tonal }

private struct FixtureCase {
    let id: String
    let description: String
    let playbackVariant: PlaybackVariant
    let includesEcho: Bool
    let includesNearEnd: Bool
    let delaySegments: [DelaySegment]
    let driftRatio: Double
    let microphoneSampleRate: Int
    let microphoneChannels: Int
    let clippingGain: Double
    let gapIntervals: [Interval]

    var trueDelaySamples: Int { delaySegments[0].delaySamples }
}

private func fixtureCases(duration: Double) -> [FixtureCase] {
    let baseDelay = 1_440 // 30 ms at 48 kHz
    let half = duration / 2
    return [
        FixtureCase(id: "far-end-only", description: "Speech-like playback through a delayed reverberant echo path; no local speech.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: false, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "near-end-only", description: "Independent local speech; playback is retained as a reference but does not enter the microphone.", playbackVariant: .speechLike, includesEcho: false, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "double-talk", description: "Concurrent tonal playback echo and independent local speech.", playbackVariant: .tonal, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "silence", description: "Silent playback, echo, local-speech, and microphone tracks.", playbackVariant: .speechLike, includesEcho: false, includesNearEnd: false, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "delay-change-mid-file", description: "Echo path delay changes halfway through the file to force reconvergence.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: false, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: half, delaySamples: baseDelay), DelaySegment(startSeconds: half, endSeconds: duration, delaySamples: baseDelay * 2)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "sample-rate-drift", description: "Echo path runs at a deterministic 500 ppm clock mismatch.", playbackVariant: .tonal, includesEcho: true, includesNearEnd: false, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1.0005, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "clipping", description: "Double-talk microphone with intentionally clipped peaks.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 2.5, gapIntervals: []),
        FixtureCase(id: "asymmetric-stereo", description: "Stereo microphone with deliberately different left and right echo/local gains.", playbackVariant: .tonal, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 2, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "microphone-44k1", description: "A 44.1 kHz microphone timeline against 48 kHz reference tracks.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: 44_100, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "microphone-16k", description: "A 16 kHz microphone timeline against 48 kHz reference tracks.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: 16_000, microphoneChannels: 1, clippingGain: 1, gapIntervals: []),
        FixtureCase(id: "documented-gaps", description: "Far-end echo and local speech with two explicit microphone capture gaps.", playbackVariant: .speechLike, includesEcho: true, includesNearEnd: true, delaySegments: [DelaySegment(startSeconds: 0, endSeconds: duration, delaySamples: baseDelay)], driftRatio: 1, microphoneSampleRate: canonicalSampleRate, microphoneChannels: 1, clippingGain: 1, gapIntervals: [Interval(startSeconds: 2, endSeconds: 2.25), Interval(startSeconds: 7, endSeconds: 7.1)]),
    ]
}

private func hashSeed(_ base: UInt64, _ text: String) -> UInt64 {
    var hash = base ^ 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x1000_0000_01B3
    }
    return hash
}

private func isIn(_ index: Int, sampleRate: Int, intervals: [Interval]) -> Bool {
    let time = Double(index) / Double(sampleRate)
    return intervals.contains { time >= $0.startSeconds && time < $0.endSeconds }
}

private func interpolation(_ samples: [Double], at index: Double) -> Double {
    guard index >= 0, index < Double(samples.count - 1) else { return 0 }
    let left = Int(index)
    let fraction = index - Double(left)
    return samples[left] + (samples[left + 1] - samples[left]) * fraction
}

private func speechLikeSignal(frames: Int, seed: UInt64, sampleRate: Int) -> [Double] {
    var random = DeterministicRandom(seed: seed)
    var samples = Array(repeating: 0.0, count: frames)
    let phraseLength = max(sampleRate / 2, 1)
    let f0A = 105 + random.nextUnit() * 65
    let f0B = 185 + random.nextUnit() * 65
    for index in 0..<frames {
        let phrasePosition = index % phraseLength
        let phrase = index / phraseLength
        let attack = min(1, Double(phrasePosition) / Double(sampleRate / 25))
        let release = min(1, Double(phraseLength - phrasePosition) / Double(sampleRate / 20))
        let voiced = (phrase % 4) != 3
        guard voiced else { continue }
        let time = Double(index) / Double(sampleRate)
        let f0 = (phrase % 2 == 0 ? f0A : f0B) + 9 * sin(2 * Double.pi * 2.4 * time)
        let harmonic = sin(2 * Double.pi * f0 * time) + 0.45 * sin(2 * Double.pi * f0 * 2.03 * time) + 0.18 * sin(2 * Double.pi * f0 * 3.11 * time)
        let formants = 0.22 * sin(2 * Double.pi * (530 + 30 * sin(time)) * time) + 0.10 * sin(2 * Double.pi * 1_460 * time)
        let noise = (random.nextUnit() * 2 - 1) * 0.025
        samples[index] = (harmonic * 0.18 + formants + noise) * attack * release
    }
    return samples
}

private func tonalSignal(frames: Int, sampleRate: Int) -> [Double] {
    (0..<frames).map { index in
        let time = Double(index) / Double(sampleRate)
        let envelope = 0.55 + 0.45 * sin(2 * Double.pi * 0.37 * time)
        return envelope * (0.28 * sin(2 * Double.pi * 311 * time) + 0.19 * sin(2 * Double.pi * 659 * time) + 0.12 * sin(2 * Double.pi * 997 * time))
    }
}

private func echoSignal(playback: [Double], fixture: FixtureCase) -> [Double] {
    let taps: [(delay: Int, gain: Double)] = [(0, 0.65), (223, 0.31), (617, 0.17), (1_133, 0.09), (1_741, 0.045)]
    return playback.indices.map { outputIndex in
        let time = Double(outputIndex) / Double(canonicalSampleRate)
        let delay = fixture.delaySegments.first(where: { time >= $0.startSeconds && time < $0.endSeconds })?.delaySamples ?? fixture.trueDelaySamples
        let sourceIndex = (Double(outputIndex - delay) / fixture.driftRatio)
        return taps.reduce(0.0) { partial, tap in partial + tap.gain * interpolation(playback, at: sourceIndex - Double(tap.delay)) }
    }
}

private func resample(_ source: [Double], from inputRate: Int, to outputRate: Int, fixture: FixtureCase) -> [Double] {
    let outputFrames = Int((Double(source.count) * Double(outputRate) / Double(inputRate)).rounded())
    return (0..<outputFrames).map { outputIndex in
        let sourceIndex = Double(outputIndex) * Double(inputRate) / Double(outputRate)
        var value = interpolation(source, at: sourceIndex)
        if isIn(outputIndex, sampleRate: outputRate, intervals: fixture.gapIntervals) { value = 0 }
        return max(-1, min(1, value))
    }
}

private func microphoneSignal(echo: [Double], local: [Double], fixture: FixtureCase, echoGain: Double = 1, localGain: Double = 1) -> [Double] {
    echo.indices.map { index in
        let enabledEchoGain = fixture.includesEcho ? echoGain : 0.0
        let enabledLocalGain = fixture.includesNearEnd ? localGain : 0.0
        return max(-1, min(1, (echo[index] * enabledEchoGain + local[index] * enabledLocalGain) * fixture.clippingGain))
    }
}

private func writeWAV(channels: [[Double]], sampleRate: Int, to url: URL) throws {
    guard let first = channels.first, channels.allSatisfy({ $0.count == first.count }) else {
        throw GeneratorError.invalidConfiguration("WAV channels must have equal frame counts")
    }
    let channelCount = channels.count
    let dataBytes = first.count * channelCount * 2
    var data = Data()
    data.reserveCapacity(44 + dataBytes)
    data.append("RIFF".data(using: .ascii)!)
    appendLE(UInt32(36 + dataBytes), to: &data)
    data.append("WAVEfmt ".data(using: .ascii)!)
    appendLE(UInt32(16), to: &data)
    appendLE(UInt16(1), to: &data)
    appendLE(UInt16(channelCount), to: &data)
    appendLE(UInt32(sampleRate), to: &data)
    appendLE(UInt32(sampleRate * channelCount * 2), to: &data)
    appendLE(UInt16(channelCount * 2), to: &data)
    appendLE(UInt16(16), to: &data)
    data.append("data".data(using: .ascii)!)
    appendLE(UInt32(dataBytes), to: &data)
    for frame in 0..<first.count {
        for channel in channels {
            let sample = max(-1, min(1, channel[frame]))
            let pcm = sample <= -1 ? Int16.min : Int16((sample * 32767).rounded())
            appendLE(UInt16(bitPattern: pcm), to: &data)
        }
    }
    try data.write(to: url, options: .atomic)
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func generate(options: Options) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
    let frameCount = Int((options.durationSeconds * Double(canonicalSampleRate)).rounded())
    for fixture in fixtureCases(duration: options.durationSeconds) {
        let directory = options.outputDirectory.appendingPathComponent(fixture.id, isDirectory: true)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let caseSeed = hashSeed(options.seed, fixture.id)
        let playback = fixture.id == "silence" ? Array(repeating: 0.0, count: frameCount) : (fixture.playbackVariant == .speechLike ? speechLikeSignal(frames: frameCount, seed: caseSeed, sampleRate: canonicalSampleRate) : tonalSignal(frames: frameCount, sampleRate: canonicalSampleRate))
        let echo = fixture.id == "silence" ? Array(repeating: 0.0, count: frameCount) : echoSignal(playback: playback, fixture: fixture)
        let local = fixture.id == "silence" ? Array(repeating: 0.0, count: frameCount) : speechLikeSignal(frames: frameCount, seed: hashSeed(caseSeed, "near"), sampleRate: canonicalSampleRate)
        let microphone48k = microphoneSignal(echo: echo, local: local, fixture: fixture)
        let microphone: [[Double]]
        if fixture.microphoneChannels == 2 {
            microphone = [
                resample(microphone48k, from: canonicalSampleRate, to: fixture.microphoneSampleRate, fixture: fixture),
                resample(microphoneSignal(echo: echo, local: local, fixture: fixture, echoGain: 0.28, localGain: 0.72), from: canonicalSampleRate, to: fixture.microphoneSampleRate, fixture: fixture),
            ]
        } else {
            microphone = [resample(microphone48k, from: canonicalSampleRate, to: fixture.microphoneSampleRate, fixture: fixture)]
        }
        try writeWAV(channels: [playback], sampleRate: canonicalSampleRate, to: directory.appendingPathComponent("playback.wav"))
        try writeWAV(channels: [echo], sampleRate: canonicalSampleRate, to: directory.appendingPathComponent("echo.wav"))
        try writeWAV(channels: [local], sampleRate: canonicalSampleRate, to: directory.appendingPathComponent("local-speech.wav"))
        try writeWAV(channels: microphone, sampleRate: fixture.microphoneSampleRate, to: directory.appendingPathComponent("microphone.wav"))
        let sidecar = FixtureSidecar(
            schemaVersion: 1, caseID: fixture.id, description: fixture.description, seed: String(format: "0x%llX", options.seed), durationSeconds: options.durationSeconds,
            playback: Track(file: "playback.wav", sampleRate: canonicalSampleRate, channels: 1, variant: fixture.playbackVariant.rawValue),
            echo: Track(file: "echo.wav", sampleRate: canonicalSampleRate, channels: 1, variant: nil),
            localSpeech: Track(file: "local-speech.wav", sampleRate: canonicalSampleRate, channels: 1, variant: "independent-speech-like"),
            microphone: Track(file: "microphone.wav", sampleRate: fixture.microphoneSampleRate, channels: fixture.microphoneChannels, variant: nil),
            trueDelaySamples: fixture.trueDelaySamples, delaySegments: fixture.delaySegments, reverbTaps: [0.65, 0.31, 0.17, 0.09, 0.045], driftRatio: fixture.driftRatio, gapIntervals: fixture.gapIntervals,
            nearEndRegions: fixture.includesNearEnd ? [Interval(startSeconds: 0, endSeconds: options.durationSeconds)] : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var json = try encoder.encode(sidecar)
        json.append(0x0A)
        try json.write(to: directory.appendingPathComponent("ground-truth.json"), options: .atomic)
    }
}

do {
    try generate(options: Options.parse())
} catch {
    FileHandle.standardError.write(Data("fixture generator: \(error)\n".utf8))
    exit(2)
}
