import AudioMetricsCore
import Foundation

private let usageText = """
Usage: audio-metrics --fixture DIRECTORY [--processed FILE] [options]

Computes the implementation-plan section 8 audio-quality metrics for a processed microphone
track against a generated fixture and its ground-truth sidecar, and writes a machine-readable
JSON report.

Required:
  --fixture DIRECTORY          Fixture case directory containing ground-truth.json.

Optional:
  --processed FILE             Processed output WAV. Defaults to the fixture's own
                               microphone.wav, which is the unprocessed baseline.
  --sidecar FILE               Override the sidecar path.
  --output FILE                Write the JSON report here instead of stdout.
  --processing-delay-ms VALUE  Processing delay the output carries (default 0).
  --convergence-seconds VALUE  Ignore blocks this soon after each reconvergence point (default 1).
  --block-ms VALUE             Analysis block length (default 10).
  --alignment-window-seconds V Leading/trailing alignment window length (default 1).
  --max-lag-ms VALUE           Half-width of the lag search (default 120).
  --clip-threshold VALUE       Clipping magnitude in 0...1 (default 0.99998).
  --min-echo-reduction-db V    Echo-reduction gate (default 20).
  --max-near-end-change-db V   Near-end level-change gate (default 1).
  --max-alignment-error-ms V   Alignment gate (default 10).
  --duration-tolerance-ms V    Duration gate (default 10).
  --true-peak-ceiling-dbtp V   True-peak ceiling gate (default -1).
  --max-clipped-samples N      Clipping gate (default 0).
  --quiet                      Suppress the human-readable summary on stderr.
  --fail-on-gate               Exit non-zero when an applicable gate fails.
  --help
"""

private struct Arguments {
    var fixture: URL?
    var processed: URL?
    var sidecar: URL?
    var output: URL?
    var quiet = false
    var failOnGate = false
    var options = MetricsOptions()
}

private enum ToolError: Error, CustomStringConvertible {
    case usage(String?)

    var description: String {
        switch self {
        case .usage(let reason): return (reason.map { "\($0)\n\n" } ?? "") + usageText
        }
    }
}

private func parse() throws -> Arguments {
    var arguments = Arguments()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    func value(_ flag: String) throws -> String {
        guard let next = iterator.next() else { throw ToolError.usage("\(flag) needs a value") }
        return next
    }
    func number(_ flag: String) throws -> Double {
        let raw = try value(flag)
        guard let parsed = Double(raw) else { throw ToolError.usage("\(flag) needs a number, got \(raw)") }
        return parsed
    }

    while let argument = iterator.next() {
        switch argument {
        case "--fixture": arguments.fixture = URL(fileURLWithPath: try value(argument), isDirectory: true)
        case "--processed": arguments.processed = URL(fileURLWithPath: try value(argument))
        case "--sidecar": arguments.sidecar = URL(fileURLWithPath: try value(argument))
        case "--output": arguments.output = URL(fileURLWithPath: try value(argument))
        case "--processing-delay-ms": arguments.options.processingDelayMilliseconds = try number(argument)
        case "--convergence-seconds": arguments.options.convergenceWindowSeconds = try number(argument)
        case "--block-ms": arguments.options.blockMilliseconds = try number(argument)
        case "--alignment-window-seconds": arguments.options.alignmentWindowSeconds = try number(argument)
        case "--max-lag-ms": arguments.options.maximumLagMilliseconds = try number(argument)
        case "--clip-threshold": arguments.options.clipThreshold = try number(argument)
        case "--min-echo-reduction-db": arguments.options.gates.minimumEchoReductionDb = try number(argument)
        case "--max-near-end-change-db": arguments.options.gates.maximumNearEndLevelChangeDb = try number(argument)
        case "--max-alignment-error-ms": arguments.options.gates.maximumAlignmentErrorMilliseconds = try number(argument)
        case "--duration-tolerance-ms": arguments.options.gates.durationToleranceMilliseconds = try number(argument)
        case "--true-peak-ceiling-dbtp": arguments.options.gates.truePeakCeilingDbTP = try number(argument)
        case "--max-clipped-samples": arguments.options.gates.maximumClippedSamples = Int(try number(argument))
        case "--quiet": arguments.quiet = true
        case "--fail-on-gate": arguments.failOnGate = true
        case "--help", "-h": throw ToolError.usage(nil)
        default: throw ToolError.usage("Unknown option: \(argument)")
        }
    }
    guard arguments.fixture != nil else { throw ToolError.usage("--fixture is required") }
    return arguments
}

private func write(_ text: String, to handle: FileHandle) {
    handle.write(Data(text.utf8))
}

do {
    let arguments = try parse()
    let report = try AudioMetricsAnalyzer.analyze(
        fixtureDirectory: arguments.fixture!,
        sidecarURL: arguments.sidecar,
        processedURL: arguments.processed,
        options: arguments.options
    )
    let json = try report.encodedJSON()
    if let output = arguments.output {
        try json.write(to: output)
    } else {
        FileHandle.standardOutput.write(json)
    }
    if !arguments.quiet {
        write(report.textSummary + "\n", to: FileHandle.standardError)
    }
    if arguments.failOnGate, !report.allApplicableGatesPassed {
        write("audio-metrics: failed gates: \(report.failedGates.map(\.name).joined(separator: ", "))\n", to: FileHandle.standardError)
        exit(1)
    }
} catch {
    write("audio-metrics: \(error)\n", to: FileHandle.standardError)
    exit(2)
}
