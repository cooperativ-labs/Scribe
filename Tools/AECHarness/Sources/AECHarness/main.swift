import AECHarnessCore
import Foundation

private let usage = """
Usage: aec-harness --reference FILE --microphone FILE --output FILE --report FILE [options]

Feeds 48 kHz WAV reference and mono microphone timelines to the pinned AEC3 bridge in fixed
480-frame / 10 ms blocks. Output is a cleaned 48 kHz mono 16-bit WAV; report is streaming JSON.

Required:
  --reference FILE             System playback WAV (mono or stereo, 48 kHz).
  --microphone FILE            Microphone WAV (mono, 48 kHz).
  --output FILE                Cleaned microphone WAV destination.
  --report FILE                Metrics JSON destination.

Optional:
  --delay-samples N            Reconstructed acoustic render-to-capture delay. When omitted,
                                estimate it only from confident correlated far-end-only audio.
                                It is converted to WebRTC's millisecond API once; it is never
                                derived from wall-clock processing duration.
  --discontinuity-samples N    Reconstructed-timeline position of a documented gap, device, or
                                route discontinuity. May be supplied more than once; each resets
                                AEC3 and starts a new convergence interval.
  --block-schedule render,capture
                                Required ordering, and the default. Render analysis is immediately
                                before the matching capture block as required by AEC3.
  --help
"""

private func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("aec-harness: \(message)\n\n\(usage)\n".utf8)); exit(2) }

var reference: URL?; var microphone: URL?; var output: URL?; var report: URL?; var delay: Int?; var discontinuities: [Int] = []; var schedule: BlockSchedule = .renderThenCapture
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    func value() -> String { guard let next = iterator.next() else { fail("\(argument) needs a value") }; return next }
    switch argument {
    case "--reference": reference = URL(fileURLWithPath: value())
    case "--microphone": microphone = URL(fileURLWithPath: value())
    case "--output": output = URL(fileURLWithPath: value())
    case "--report": report = URL(fileURLWithPath: value())
    case "--delay-samples": guard let parsed = Int(value()), parsed >= 0 else { fail("--delay-samples needs a non-negative integer") }; delay = parsed
    case "--discontinuity-samples": guard let parsed = Int(value()), parsed >= 0 else { fail("--discontinuity-samples needs a non-negative integer") }; discontinuities.append(parsed)
    case "--block-schedule": do { schedule = try BlockSchedule(argument: value()) } catch { fail(error.localizedDescription) }
    case "--help", "-h": print(usage); exit(0)
    default: fail("Unknown option \(argument)")
    }
}
guard let reference, let microphone, let output, let report else { fail("--reference, --microphone, --output, and --report are required") }
do {
    try AECHarnessRunner.run(AECHarnessOptions(referenceURL: reference, microphoneURL: microphone, outputURL: output, reportURL: report, renderToCaptureDelaySamples: delay, discontinuitySamples: discontinuities, blockSchedule: schedule))
    FileHandle.standardError.write(Data("aec-harness: wrote \(output.path) and \(report.path)\n".utf8))
} catch { fail(error.localizedDescription) }
