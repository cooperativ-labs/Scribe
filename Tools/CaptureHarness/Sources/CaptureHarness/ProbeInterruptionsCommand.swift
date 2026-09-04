import Foundation

/// `capture-harness probe-interruptions` — the interruption half of the device matrix.
///
/// Runs a normal capture while watching the system events IMPLEMENTATION_PLAN.md section 8
/// requires the MVP interruption policy to be based on, journals each event onto the same
/// timeline as the audio, then reports what the stream actually did around each one:
/// continued, continued with a timestamp gap, changed format, errored, or stopped.
///
/// The operator drives the scenarios; the harness only observes and measures. Nothing here
/// simulates an event, because the point is to learn what macOS really does.
enum ProbeInterruptionsCommand {
    static let scenarioScript = """
    Perform these while the capture runs, pausing ~20 s between them so each shows up
    as a separate region of the timeline. Keep audio playing throughout.

      1. Output route: switch playback from the built-in speakers to headphones or a
         Bluetooth device, and back.
      2. Microphone disconnection: unplug the USB microphone that is being captured, wait,
         then plug it back in.
      3. Screen lock: lock the screen (Control-Command-Q), wait ~30 s, unlock.
      4. Sleep/wake: sleep the Mac, wait ~30 s, wake it.
      5. Selected-application exit: quit the captured application, then relaunch it.

    Stop with Ctrl-C when finished, or let --duration expire.
    """

    static func run(_ raw: [String]) async -> Int32 {
        do {
            let arguments = try Arguments(raw)
            let bundleIdentifier = arguments.string("bundle-id")
            let allSystemAudio = arguments.flag("all-system-audio")
            guard bundleIdentifier != nil || allSystemAudio else {
                throw ArgumentError(message: "Pass --bundle-id <identifier> or --all-system-audio.")
            }
            let scope: CaptureScope = bundleIdentifier.map { .application(bundleIdentifier: $0) } ?? .allSystemAudio
            let directory = arguments.string("output").map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("captures")
                    .appendingPathComponent("interruptions \(Timestamp.sessionStamp())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let options = RecordOptions(
                outputDirectory: directory,
                scope: scope,
                microphoneDeviceID: arguments.string("microphone-uid"),
                durationSeconds: try arguments.double("duration", default: 900),
                sampleRate: try arguments.int("sample-rate", default: 48_000),
                channelCount: try arguments.int("channels", default: 2),
                screenConsumer: .none,
                fallbackToMinimalScreen: false,
                startTimeoutSeconds: 0,
                segmentSeconds: try arguments.double("segment-seconds", default: 0),
                cpuSampleSeconds: try arguments.double("cpu-sample-seconds", default: 15),
                watchProcessName: arguments.string("watch-process") ?? "replayd"
            )

            let journal = try JournalWriter(directory: directory)
            defer { journal.synchronizeAndClose() }
            journal.appendEvent([
                "record": "session-start",
                "tool": "capture-harness probe-interruptions",
                "scope": scope.describedScope,
                "durationSeconds": options.durationSeconds,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "defaultOutput": AudioDeviceCatalog.describeDefault(scope: .output),
                "defaultInput": AudioDeviceCatalog.describeDefault(scope: .input),
            ])

            let observer = InterruptionObserver(watching: Set([bundleIdentifier].compactMap { $0 })) { marker in
                journal.appendEvent(marker.journalObject)
                print("  [\(marker.wallClock)] \(marker.name): \(marker.detail)")
            }
            observer.start()
            defer { observer.stop() }

            let session = CaptureSession(options: options, journal: journal)
            print("Recording to \(directory.path)")
            print("Scope: \(scope.describedScope)")
            try await session.start()
            print("Stream started.\n")
            print(scenarioScript)
            print("")

            let reason = await session.waitForStop()
            let report = await session.stop(reason: reason)
            journal.synchronizeAndClose()

            let buffers = try InterruptionAnalysis.buffers(inTimeline: journal.timelineURL)
            let markers = try InterruptionAnalysis.markers(inEvents: journal.eventsURL)
            let outcomes = InterruptionAnalysis.correlate(markers: markers, buffers: buffers)

            var summary = report.manifest
            summary["tool"] = "capture-harness probe-interruptions"
            summary["interruptions"] = outcomes.map(\.journalObject)
            summary["observedEventCount"] = outcomes.count
            let summaryURL = directory.appendingPathComponent("interruption-probe.json")
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: summaryURL)

            print("\n" + report.humanSummary)
            print("\nObserved system events: \(outcomes.count)")
            for outcome in outcomes { print("  " + outcome.described) }
            if outcomes.isEmpty {
                print("  None. Either no scenario was performed, or macOS delivered no notification for it — both are results worth recording.")
            }
            print("\nSummary: \(summaryURL.path)")
            return report.streamErrorMessage == nil ? 0 : 1
        } catch {
            fputs("capture-harness probe-interruptions: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}
