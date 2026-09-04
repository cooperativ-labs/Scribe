import Foundation
import TranscriptionWorkerSupport

/// Repeatable whole-file offline diarization probe. Run this under
/// `/usr/bin/time -l` to capture peak RSS, because Core ML memory is not
/// observable reliably from inside the process.
@main
struct DiarizationBenchmark {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let manifest = try ModelManifest.load(from: options.manifestURL)
            let adapter = OfflineDiarizationAdapter(
                manifest: manifest,
                modelsDirectory: options.modelsURL,
                configuration: .init(knownSpeakerCount: options.knownSpeakerCount)
            )
            let startedAt = ContinuousClock.now
            let result = try await adapter.diarize(fileURL: options.audioURL)
            let elapsed = seconds(startedAt.duration(to: .now))
            let output = Output(
                audioPath: options.audioURL.path,
                knownSpeakerCount: options.knownSpeakerCount,
                sourceDurationSeconds: result.sourceDurationSeconds,
                wallClockSeconds: elapsed,
                intervals: result.intervals,
                embeddings: result.embeddings,
                timings: result.timings,
                usedDiskBackedAudio: result.usedDiskBackedAudio
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("DiarizationBenchmark failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
}

private struct Output: Codable {
    let audioPath: String
    let knownSpeakerCount: Int?
    let sourceDurationSeconds: Double
    let wallClockSeconds: Double
    let intervals: [OfflineDiarizationAdapter.SpeakerInterval]
    let embeddings: [OfflineDiarizationAdapter.SpeakerEmbedding]
    let timings: OfflineDiarizationAdapter.Timings?
    let usedDiskBackedAudio: Bool
}

private struct Options {
    let audioURL: URL
    let manifestURL: URL
    let modelsURL: URL
    let knownSpeakerCount: Int?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else { throw OptionsError.usage }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let audio = values["--audio"], let manifest = values["--manifest"], let models = values["--models"] else {
            throw OptionsError.usage
        }
        if let count = values["--known-speaker-count"] {
            guard let parsed = Int(count), parsed > 0 else { throw OptionsError.usage }
            knownSpeakerCount = parsed
        } else {
            knownSpeakerCount = nil
        }
        audioURL = URL(fileURLWithPath: audio)
        manifestURL = URL(fileURLWithPath: manifest)
        modelsURL = URL(fileURLWithPath: models, isDirectory: true)
    }
}

private enum OptionsError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: DiarizationBenchmark --audio <audio-file> --manifest <model_manifest.json> --models <models-dir> [--known-speaker-count <positive-int>]"
    }
}
