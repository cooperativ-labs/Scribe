import Foundation
import TranscriptionWorkerSupport

/// Minimal offline harness. Invoke it under `/usr/bin/time -l` when recording
/// peak RSS; the harness itself reports only ASR elapsed time and output.
@main
struct ASRBenchmark {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let manifest = try ModelManifest.load(from: options.manifestURL)
            let adapter = ParakeetAdapter(
                manifest: manifest,
                modelsDirectory: options.modelsURL,
                configuration: .init(computeUnits: options.computeUnits)
            )
            let startedAt = ContinuousClock.now
            let transcript = try await adapter.transcribe(fileURL: options.audioURL)
            let elapsedComponents = startedAt.duration(to: .now).components
            let elapsed = Double(elapsedComponents.seconds)
                + Double(elapsedComponents.attoseconds) / 1_000_000_000_000_000_000
            let output = BenchmarkOutput(
                audioPath: options.audioURL.path,
                computeUnits: options.computeUnits.rawValue,
                sourceDurationSeconds: transcript.sourceDurationSeconds,
                wallClockSeconds: elapsed,
                asrProcessingSeconds: transcript.processingTimeSeconds,
                tokens: transcript.tokens.count,
                text: transcript.text,
                timestampUnit: transcript.timestampUnit,
                usedChunkedProcessing: transcript.usedChunkedProcessing,
                firstTokenStartSeconds: transcript.tokens.first?.startSeconds,
                lastTokenEndSeconds: transcript.tokens.last?.endSeconds,
                timingsAreMonotonicAndInBounds: timingsAreMonotonicAndInBounds(transcript)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("ASRBenchmark failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

private func timingsAreMonotonicAndInBounds(_ transcript: ParakeetAdapter.Transcript) -> Bool {
    var previousStart = -Double.infinity
    for token in transcript.tokens {
        guard token.startSeconds >= previousStart,
              token.startSeconds >= 0,
              token.endSeconds >= token.startSeconds,
              token.endSeconds <= transcript.sourceDurationSeconds else {
            return false
        }
        previousStart = token.startSeconds
    }
    return true
}

private struct BenchmarkOutput: Codable {
    let audioPath: String
    let computeUnits: String
    let sourceDurationSeconds: Double
    let wallClockSeconds: Double
    let asrProcessingSeconds: Double
    let tokens: Int
    let text: String
    let timestampUnit: String
    let usedChunkedProcessing: Bool
    let firstTokenStartSeconds: Double?
    let lastTokenEndSeconds: Double?
    let timingsAreMonotonicAndInBounds: Bool
}

private struct Options {
    let audioURL: URL
    let manifestURL: URL
    let modelsURL: URL
    let computeUnits: ASRComputeUnits

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else {
                throw OptionsError.usage
            }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let audio = values["--audio"], let manifest = values["--manifest"], let models = values["--models"],
              let rawComputeUnits = values["--compute-units"], let computeUnits = ASRComputeUnits(rawValue: rawComputeUnits) else {
            throw OptionsError.usage
        }
        audioURL = URL(fileURLWithPath: audio)
        manifestURL = URL(fileURLWithPath: manifest)
        modelsURL = URL(fileURLWithPath: models, isDirectory: true)
        self.computeUnits = computeUnits
    }
}

private enum OptionsError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: ASRBenchmark --audio <16k-mono-file> --manifest <model_manifest.json> --models <models-dir> --compute-units <cpuOnly|cpuAndGPU|cpuAndNeuralEngine|all>"
    }
}
