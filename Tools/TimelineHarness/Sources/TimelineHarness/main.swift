import Foundation
import Processing
import ScribeAppCore
import TimelineHarnessSupport

private let usage = """
Usage: timeline-harness <command> [options]

Commands:
  fixtures   Synthesize a capture session from each synthetic fixture, reconstruct
             its microphone track with TimelineBuilder, and write the result as
             32-bit float WAV for Tools/AudioMetrics to score.
  mixdown    Synthesize a capture session from each fixture, run the echo
             canceller and mixdown over it, and write the cleaned microphone and
             the decoded final mix for Tools/AudioMetrics to score.
  session    Reconstruct a real recorder session directory and report its plan.

Options for `fixtures`:
  --fixtures DIRECTORY   Root holding the fixture case directories
                         (default Tests/Fixtures/Generated).
  --case NAME            Run one case; repeatable. Default: every case.
  --work DIRECTORY       Where sessions and output WAVs are written (required).
  --json FILE            Write the harness report here instead of stdout.

Options for `mixdown`:
  --fixtures DIRECTORY   Root holding the fixture case directories
                         (default Tests/Fixtures/Generated).
  --real DIRECTORY       Root holding real-room fixtures (system.wav /
                         microphone.wav pairs); repeatable alongside --fixtures.
  --case NAME            Run one case; repeatable. Default: every case.
  --work DIRECTORY       Where sessions and output WAVs are written (required).
  --json FILE            Write the harness report here instead of stdout.

Options for `session`:
  --session DIRECTORY    A recorder session directory containing capture/.
  --output DIRECTORY     Write reconstructed <track>.wav files here.
  --json FILE            Write the plan report here instead of stdout.
"""

enum Harness {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("timeline-harness: \(message)\n".utf8))
        exit(2)
    }

    static func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, !command.hasPrefix("-") else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    arguments.removeFirst()

    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    func options(_ name: String) -> [String] {
        var values: [String] = []
        for (index, argument) in arguments.enumerated() where argument == name && index + 1 < arguments.count {
            values.append(arguments[index + 1])
        }
        return values
    }

    func emit(_ object: Any, to path: String?) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let path { try data.write(to: URL(fileURLWithPath: path)) } else { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
    }

    do {
        switch command {
        case "fixtures":
            let root = URL(fileURLWithPath: option("--fixtures") ?? "Tests/Fixtures/Generated", isDirectory: true)
            guard let work = option("--work") else { fail("--work is required") }
            let workDirectory = URL(fileURLWithPath: work, isDirectory: true)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

            var cases = options("--case")
            if cases.isEmpty {
                cases = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("ground-truth.json").path) }
                    .sorted()
            }
            guard !cases.isEmpty else { fail("no fixture cases under \(root.path)") }

            var reports: [[String: Any]] = []
            for (index, name) in cases.enumerated() {
                let result = try FixtureSession.run(
                    fixtureDirectory: root.appendingPathComponent(name, isDirectory: true),
                    workingDirectory: workDirectory,
                    offsetIndex: index
                )
                reports.append([
                    "case": result.caseID,
                    "sessionDirectory": result.sessionDirectory.path,
                    "processed": result.processedURL.path,
                    "aligned": result.alignedURL.path,
                    "expectedLeadingSilenceFrames": result.expectedLeadingSilenceFrames,
                    "microphoneOffsetSeconds": result.microphoneOffsetSeconds,
                    "microphoneLeadingSilenceFrames": result.microphoneLeadingSilenceFrames,
                    "processingDelayMs": result.processingDelayMilliseconds,
                    "injectedDriftPPM": result.injectedDriftPPM,
                    "measuredDriftPPM": result.measuredDriftPPM,
                    "driftCorrected": result.driftCorrected,
                    "reconstructedFrames": result.reconstructedFrames,
                    "sourceMicrophoneFrames": result.sourceMicrophoneFrames,
                    "journaledGapSeconds": result.journaledGapSeconds,
                    "diagnostics": result.diagnostics,
                ])
                FileHandle.standardError.write(Data("reconstructed \(result.caseID): offset \(String(format: "%.6f", result.microphoneOffsetSeconds))s, drift \(String(format: "%.3f", result.measuredDriftPPM)) ppm\(result.driftCorrected ? " (corrected)" : "")\n".utf8))
            }
            try emit(["schemaVersion": 1, "cases": reports], to: option("--json"))

        case "mixdown":
            let root = URL(fileURLWithPath: option("--fixtures") ?? "Tests/Fixtures/Generated", isDirectory: true)
            guard let work = option("--work") else { fail("--work is required") }
            let workDirectory = URL(fileURLWithPath: work, isDirectory: true)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

            var selected = options("--case")
            var jobs: [(directory: URL, real: Bool)] = []
            if FileManager.default.fileExists(atPath: root.path) {
                var cases = selected
                if cases.isEmpty {
                    cases = try FileManager.default.contentsOfDirectory(atPath: root.path)
                        .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("ground-truth.json").path) }
                        .sorted()
                }
                jobs += cases.map { (root.appendingPathComponent($0, isDirectory: true), false) }
            }
            for realRoot in options("--real") {
                let directory = URL(fileURLWithPath: realRoot, isDirectory: true)
                var cases = selected
                if cases.isEmpty {
                    cases = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("system.wav").path) }
                        .sorted()
                }
                jobs += cases.map { (directory.appendingPathComponent($0, isDirectory: true), true) }
            }
            selected = []
            guard !jobs.isEmpty else { fail("no fixture cases to run") }

            var mixdownReports: [[String: Any]] = []
            for job in jobs {
                let result = job.real
                    ? try MixdownSession.runRealFixture(fixtureDirectory: job.directory, workingDirectory: workDirectory)
                    : try MixdownSession.runFixture(fixtureDirectory: job.directory, workingDirectory: workDirectory)
                mixdownReports.append([
                    "case": result.caseID,
                    "real": job.real,
                    "fixtureDirectory": job.directory.path,
                    "sessionDirectory": result.sessionDirectory.path,
                    "cleanedMicrophone": result.cleanedMicrophoneURL.path,
                    "finalMix": result.finalMixURL.path,
                    "finalFLAC": result.finalFLACURL.path,
                    "decision": result.decision,
                    "delaySamples": result.delaySamples as Any,
                    "delayCorrelation": result.delayCorrelation as Any,
                    "delayBasis": result.delayBasis as Any,
                    "delaySegments": result.delaySegments,
                    "analysisWindows": result.analysisWindows,
                    "processingLatencyFrames": result.processingLatencyFrames,
                    "reconvergenceSeconds": result.reconvergenceSeconds,
                    "truePeakBeforeGainDbTP": result.truePeakBeforeGainDbTP as Any,
                    "appliedPeakGain": result.appliedPeakGain,
                    "echoReturnLossEnhancementDb": result.echoReturnLossEnhancementDb as Any,
                    "residualEchoLikelihood": result.residualEchoLikelihood as Any,
                    "frameCount": result.frameCount,
                    "checksum": result.checksum,
                    "failure": result.failure as Any,
                    "microphoneLeadFrames": result.microphoneLeadFrames,
                    "windows": result.windows,
                    "windowRejections": result.windowRejections,
                ])
                let detail = result.failure.map { "failed: \($0)" }
                    ?? "\(result.decision), delay \(result.delaySamples.map(String.init) ?? "n/a") samples via \(result.delayBasis ?? "n/a")"
                FileHandle.standardError.write(Data("mixed \(result.caseID): \(detail)\n".utf8))
            }
            try emit(["schemaVersion": 1, "cases": mixdownReports], to: option("--json"))

        case "session":
            guard let session = option("--session") else { fail("--session is required") }
            let sessionDirectory = URL(fileURLWithPath: session, isDirectory: true)
            let builder = try TimelineBuilder.plan(sessionDirectory: sessionDirectory)
            var tracks: [[String: Any]] = []
            for track in builder.timeline.tracks {
                if let output = option("--output"), let reader = try builder.makeReader(for: track.track) {
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try WAVAudio(sampleRate: timelineSampleRate, channels: try reader.readAll())
                        .write(to: directory.appendingPathComponent("\(track.track.rawValue).wav"))
                }
                tracks.append([
                    "track": track.track.rawValue,
                    "nativeFormat": track.nativeFormat.description,
                    "firstTimestampSeconds": track.firstTimestamp.seconds,
                    "leadingSilenceFrames": track.leadingSilenceFrames,
                    "runs": track.runs.count,
                    "gaps": track.gaps.map { ["startSeconds": $0.startTimestamp.seconds, "durationSeconds": $0.duration.seconds, "outputFrames": $0.outputFrameCount] },
                    "driftPPM": track.drift.partsPerMillion,
                    "driftCorrected": track.drift.corrected,
                    "driftRationale": track.drift.rationale,
                    "outputFrameCount": track.outputFrameCount,
                    "durationSeconds": track.durationSeconds,
                    "channelCount": track.channelCount,
                    "diagnostics": track.diagnostics.map { "\($0.code): \($0.message)" },
                ])
            }
            try emit([
                "schemaVersion": 1,
                "originSeconds": builder.timeline.origin.seconds,
                "durationSeconds": builder.timeline.durationSeconds,
                "outputFrameCount": builder.timeline.outputFrameCount,
                "tracks": tracks,
                "diagnostics": builder.timeline.diagnostics.map { "\($0.code): \($0.message)" },
            ], to: option("--json"))

        default:
            fail("unknown command \(command)\n\n\(usage)")
        }
    } catch {
        fail("\(error)")
    }
    }
}

do { try Harness.main() } catch { Harness.fail("\(error)") }
