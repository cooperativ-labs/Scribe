import Foundation
import ScribeAppCore

/// Uses exactly the recorder's journal reconstruction: offsets, drift and gaps.
/// Measures original tracks before mix gains/AEC; echo and double-talk abstain.
public enum SourceEnergyPreparation {
    public static func timeline(sessionDirectory: URL) throws -> SourceEnergyTimeline? {
        let manifestURL = sessionDirectory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("capture/timeline.jsonl").path)
        else { return nil }
        let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: manifestURL))
        guard manifest.processing.state == .complete else { return nil }
        let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory)
        return try timeline(builder: builder)
    }

    static func timeline(builder: TimelineBuilder) throws -> SourceEnergyTimeline? {
        guard let microphone = try builder.makeReader(for: .microphone),
              let system = try builder.makeReader(for: .system) else { return nil }
        let frames = max(microphone.frameCount, system.frameCount)
        let count = Int((frames + 4_799) / 4_800)
        func powers(_ reader: TimelineTrackReader) throws -> (sums: [Double], captured: [Int]) {
            var sums = [Double](repeating: 0, count: count)
            var captured = [Int](repeating: 0, count: count)
            while let block = try reader.read(maxFrames: 4_800) {
                try Task.checkCancellation()
                for frame in 0..<block.frameCount {
                    let bin = Int((block.startFrame + Int64(frame)) / 4_800)
                    // Mean channel power avoids cancelling stereo channels.
                    let power = block.channels.reduce(0.0) { $0 + Double($1[frame]) * Double($1[frame]) } / Double(block.channels.count)
                    sums[bin] += power
                    if !block.isSilence { captured[bin] += 1 }
                }
            }
            return (sums, captured)
        }
        let mic = try powers(microphone), sys = try powers(system)
        return SourceEnergyTimeline(windows: (0..<count).map { index in
            let n = Int(min(4_800, frames - Int64(index * 4_800)))
            return .init(startMs: index * 100, endMs: Int((min(frames, Int64((index + 1) * 4_800)) * 1_000 + 47_999) / 48_000),
                         microphonePower: mic.sums[index] / Double(n), systemPower: sys.sums[index] / Double(n),
                         bothTracksPresent: mic.captured[index] == n && sys.captured[index] == n)
        })
    }
}
