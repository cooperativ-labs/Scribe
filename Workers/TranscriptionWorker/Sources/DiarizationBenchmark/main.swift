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
                configuration: .init(
                    knownSpeakerCount: options.knownSpeakerCount,
                    clusteringThreshold: options.clusteringThreshold,
                    embeddingExcludeOverlap: options.embeddingExcludeOverlap,
                    minimumEmbeddingDurationSeconds: options.minimumEmbeddingDurationSeconds,
                    segmentationStepRatio: options.segmentationStepRatio
                )
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
                usedDiskBackedAudio: result.usedDiskBackedAudio,
                engine: result.engine,
                configuration: result.configuration,
                clusteringDiagnostics: result.clusteringDiagnostics
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
    let engine: OfflineDiarizationAdapter.Engine
    let configuration: OfflineDiarizationAdapter.AppliedConfiguration
    let clusteringDiagnostics: OfflineDiarizationAdapter.ClusteringDiagnostics
}

private struct Options {
    let audioURL: URL
    let manifestURL: URL
    let modelsURL: URL
    let knownSpeakerCount: Int?
    let clusteringThreshold: Double
    let embeddingExcludeOverlap: Bool
    let minimumEmbeddingDurationSeconds: Double
    let segmentationStepRatio: Double

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
        clusteringThreshold = try Self.double(values["--clustering-threshold"], default: 0.6)
        embeddingExcludeOverlap = try Self.bool(values["--embedding-exclude-overlap"], default: true)
        minimumEmbeddingDurationSeconds = try Self.double(values["--minimum-embedding-duration"], default: 1.0)
        segmentationStepRatio = try Self.double(values["--segmentation-step-ratio"], default: 0.2)
    }

    private static func double(_ value: String?, default defaultValue: Double) throws -> Double {
        guard let value else { return defaultValue }
        guard let parsed = Double(value) else { throw OptionsError.usage }
        return parsed
    }

    private static func bool(_ value: String?, default defaultValue: Bool) throws -> Bool {
        guard let value else { return defaultValue }
        switch value {
        case "true": return true
        case "false": return false
        default: throw OptionsError.usage
        }
    }
}

private enum OptionsError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: DiarizationBenchmark --audio <audio-file> --manifest <model_manifest.json> --models <models-dir> [--known-speaker-count <positive-int>] [--clustering-threshold <0...2>] [--embedding-exclude-overlap <true|false>] [--minimum-embedding-duration <seconds>] [--segmentation-step-ratio <0...1>]"
    }
}
