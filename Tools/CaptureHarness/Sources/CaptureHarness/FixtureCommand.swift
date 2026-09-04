import AVFoundation
import Foundation

/// One real-room capture scenario from IMPLEMENTATION_PLAN.md section 8. The synthetic
/// suite under `Tests/Fixtures/Generated` covers the same names; these are the real-room
/// recordings the plan says must accompany them, because synthetic success alone is
/// insufficient.
struct FixtureScenario: Sendable {
    let key: String
    let title: String
    /// What the operator must do, printed before the countdown.
    let script: String
    /// What a correct recording should contain, written into the sidecar so a later reader
    /// can tell whether a fixture matches its label without listening to it first.
    let expectation: String

    static let all: [FixtureScenario] = [farEndOnly, nearEndOnly, doubleTalk]

    static let farEndOnly = FixtureScenario(
        key: "far-end-only",
        title: "Far-end only",
        script: """
        Play far-end speech through the speakers under test. Do not speak, and keep the room
        as quiet as the room normally is. The microphone should pick up only the acoustic
        echo of the playback.
        """,
        expectation: "System track carries far-end speech; microphone track carries its acoustic echo and room noise only, with no near-end speech."
    )

    static let nearEndOnly = FixtureScenario(
        key: "near-end-only",
        title: "Near-end only",
        script: """
        Say nothing until the countdown ends, then speak continuously into the microphone
        under test. Nothing should be playing back: no meeting audio, no music, no alerts.
        """,
        expectation: "System track is silent or digital silence; microphone track carries near-end speech only. Used to check that AEC does not attenuate local speech."
    )

    static let doubleTalk = FixtureScenario(
        key: "double-talk",
        title: "Double-talk",
        script: """
        Play far-end speech through the speakers under test and speak over it for most of
        the take, including at least two passages where both talk at once.
        """,
        expectation: "System track carries far-end speech; microphone track carries near-end speech overlapping the echo. Used for the double-talk listening check."
    )

    static func named(_ key: String) -> FixtureScenario? {
        all.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }
}

/// `capture-harness fixture` — records one labelled real system/microphone pair and files it
/// under `Tests/Fixtures/real/<id>/` with a sidecar describing the devices, formats, and
/// timing, so the recording can be trusted later without re-deriving how it was made.
enum FixtureCommand {
    static func run(_ raw: [String]) async -> Int32 {
        do {
            let arguments = try Arguments(raw)
            guard let scenarioKey = arguments.string("scenario"), let scenario = FixtureScenario.named(scenarioKey) else {
                throw ArgumentError(message: "Pass --scenario with one of: \(FixtureScenario.all.map(\.key).joined(separator: ", ")).")
            }
            guard let identifier = arguments.string("id") else {
                throw ArgumentError(message: "Pass --id <directory-name>, e.g. --id builtin-far-end-only or --id usb-double-talk.")
            }
            guard let deviceNotes = arguments.string("devices") else {
                throw ArgumentError(message: "Pass --devices \"<playback and microphone hardware>\". A fixture without its device configuration cannot be interpreted.")
            }
            let bundleIdentifier = arguments.string("bundle-id")
            let allSystemAudio = arguments.flag("all-system-audio")
            guard bundleIdentifier != nil || allSystemAudio else {
                throw ArgumentError(message: "Pass --bundle-id <identifier> or --all-system-audio.")
            }
            let scope: CaptureScope = bundleIdentifier.map { .application(bundleIdentifier: $0) } ?? .allSystemAudio
            let seconds = try arguments.double("seconds", default: 15)
            let lead = try arguments.double("lead-in", default: 5)
            let fixtureFormat = try FixtureFormat(argument: arguments.string("format") ?? "wav")

            let fixturesRoot = URL(fileURLWithPath: arguments.string("fixtures-dir") ?? "Tests/Fixtures/real")
            let fixtureDirectory = fixturesRoot.appendingPathComponent(identifier)
            let workingDirectory = arguments.string("output").map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("captures")
                    .appendingPathComponent("fixture \(identifier) \(Timestamp.sessionStamp())")
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

            print("Fixture: \(identifier) — \(scenario.title)")
            print("Devices: \(deviceNotes)")
            print("Default output: \(AudioDeviceCatalog.describeDefault(scope: .output))")
            print("Default input:  \(AudioDeviceCatalog.describeDefault(scope: .input))")
            print("\n\(scenario.script)\n")
            for remaining in stride(from: Int(lead), to: 0, by: -1) {
                print("Starting in \(remaining)…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            print("Recording \(Int(seconds)) s — go.")

            let outcome = await ProbeRun.capture(
                label: identifier,
                scope: scope,
                seconds: seconds,
                microphoneDeviceID: arguments.string("microphone-uid"),
                directory: workingDirectory
            )
            guard let report = outcome.report else {
                throw ArgumentError(message: "Capture failed: \(outcome.failure ?? "unknown error"). Nothing was written to \(fixtureDirectory.path).")
            }
            print("Done.\n\(report.humanSummary)")

            let inspection = try? TimestampInspector.inspect(journalURL: workingDirectory.appendingPathComponent("timeline.jsonl"))
            let exports = try export(
                report: report,
                from: workingDirectory,
                to: fixtureDirectory,
                format: fixtureFormat
            )
            let sidecar = manifest(
                identifier: identifier,
                scenario: scenario,
                deviceNotes: deviceNotes,
                scope: scope,
                seconds: seconds,
                report: report,
                inspection: inspection,
                exports: exports,
                workingDirectory: workingDirectory,
                operatorNotes: arguments.string("notes")
            )
            try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: fixtureDirectory.appendingPathComponent("fixture.json"))

            print("\nFixture written to \(fixtureDirectory.path)")
            for export in exports { print("  \(export.name) — \(export.described)") }
            print("  fixture.json — scenario, devices, formats, timing")
            print("Raw capture (timeline.jsonl, CAF originals) kept at \(workingDirectory.path); it is deliberately not copied into the repository.")
            return 0
        } catch {
            fputs("capture-harness fixture: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    enum FixtureFormat: String, Sendable {
        case wav
        case flac

        init(argument: String) throws {
            guard let value = FixtureFormat(rawValue: argument.lowercased()) else {
                throw ArgumentError(message: "--format expects wav or flac, got \(argument)")
            }
            self = value
        }

        var fileExtension: String { rawValue }

        /// 16-bit is chosen to match the existing synthetic suite and to keep committed
        /// fixtures small; the unconverted float originals stay in the capture directory.
        func settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
            switch self {
            case .wav:
                return [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            case .flac:
                return [
                    AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                ]
            }
        }
    }

    struct Export: Sendable {
        let name: String
        let track: String
        let sampleRate: Double
        let channels: Int
        let frames: Int64
        let byteSize: Int
        let sourceSegments: [String]

        var described: String {
            String(format: "%@, %.0f Hz, %d ch, %lld frames, %.1f MB", track, sampleRate, channels, frames, Double(byteSize) / 1_048_576)
        }

        var journalObject: [String: Any] {
            [
                "file": name,
                "track": track,
                "sampleRate": sampleRate,
                "channels": channels,
                "frames": frames,
                "bytes": byteSize,
                "sourceSegments": sourceSegments,
            ]
        }
    }

    /// Concatenates each track's CAF segments into one committed file. Segments only ever
    /// split on a format change here (the fixture capture sets no length-based rotation), so
    /// more than one segment means the format changed mid-take and the fixture is suspect;
    /// that is recorded rather than hidden.
    static func export(report: CaptureReport, from source: URL, to destination: URL, format: FixtureFormat) throws -> [Export] {
        var exports: [Export] = []
        for (track, summary) in [("system", report.system), ("microphone", report.microphone)] {
            guard !summary.segments.isEmpty else { continue }
            let outputURL = destination.appendingPathComponent("\(track).\(format.fileExtension)")
            try? FileManager.default.removeItem(at: outputURL)

            var output: AVAudioFile?
            var frames: Int64 = 0
            var sampleRate: Double = 0
            var channels = 0
            for segment in summary.segments {
                let input = try AVAudioFile(forReading: source.appendingPathComponent(segment))
                let processing = input.processingFormat
                if output == nil {
                    sampleRate = processing.sampleRate
                    channels = Int(processing.channelCount)
                    output = try AVAudioFile(
                        forWriting: outputURL,
                        settings: format.settings(sampleRate: processing.sampleRate, channels: processing.channelCount)
                    )
                }
                // Read to the declared length rather than waiting for a zero-frame read:
                // AVAudioFile signals the end of some files by throwing eofErr instead.
                let chunk = AVAudioFrameCount(processing.sampleRate)
                while input.framePosition < input.length {
                    let remaining = AVAudioFrameCount(min(Int64(chunk), input.length - input.framePosition))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: remaining) else { break }
                    try input.read(into: buffer, frameCount: remaining)
                    if buffer.frameLength == 0 { break }
                    try output?.write(from: buffer)
                    frames += Int64(buffer.frameLength)
                }
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            exports.append(Export(
                name: outputURL.lastPathComponent,
                track: track,
                sampleRate: sampleRate,
                channels: channels,
                frames: frames,
                byteSize: size,
                sourceSegments: summary.segments
            ))
        }
        return exports
    }

    static func manifest(
        identifier: String,
        scenario: FixtureScenario,
        deviceNotes: String,
        scope: CaptureScope,
        seconds: Double,
        report: CaptureReport,
        inspection: InspectionReport?,
        exports: [Export],
        workingDirectory: URL,
        operatorNotes: String?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "tool": "capture-harness fixture",
            "id": identifier,
            "scenario": scenario.key,
            "title": scenario.title,
            "expectation": scenario.expectation,
            "devices": deviceNotes,
            "scope": scope.describedScope,
            "filter": report.filterDescription,
            "microphone": report.microphoneDescription,
            "requestedSeconds": seconds,
            "recordedSeconds": report.elapsedSeconds,
            "files": exports.map(\.journalObject),
            "tracks": ["audio": report.system.journalObject, "microphone": report.microphone.journalObject],
            "callbackThreads": report.callbackThreads,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "rawCaptureDirectory": workingDirectory.path,
            "recordedAt": Timestamp.iso8601(),
            "formatChangedMidTake": exports.contains { $0.sourceSegments.count > 1 },
        ]
        if let operatorNotes { object["notes"] = operatorNotes }
        if let inspection, let data = try? JSONEncoder().encode(inspection),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            object["timing"] = decoded
        }
        return object
    }
}
