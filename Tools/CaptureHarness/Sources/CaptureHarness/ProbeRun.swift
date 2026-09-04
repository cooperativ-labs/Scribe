import Foundation

/// Runs one short capture for a probe and returns its report, or the error that
/// prevented it. Probe runs never use the start timeout or the minimal-screen retry:
/// a filter that legitimately delivers nothing is a *result*, not a failure to retry.
enum ProbeRun {
    struct Outcome: Sendable {
        let label: String
        let scope: String
        let directory: URL
        let report: CaptureReport?
        let failure: String?

        var deliveredBuffers: Int { (report?.system.bufferCount ?? 0) + (report?.microphone.bufferCount ?? 0) }

        var journalObject: [String: Any] {
            var object: [String: Any] = [
                "variant": label,
                "scope": scope,
                "directory": directory.lastPathComponent,
            ]
            if let report {
                object["stopReason"] = report.reason.rawValue
                object["filter"] = report.filterDescription
                object["systemAudio"] = report.system.journalObject
                object["microphone"] = report.microphone.journalObject
                object["verdict"] = verdict
                if let streamError = report.streamErrorMessage { object["streamError"] = streamError }
            }
            if let failure { object["failure"] = failure }
            return object
        }

        /// The question this probe exists to answer, stated in the terms the plan uses.
        var verdict: String {
            guard let report else { return "not run: \(failure ?? "unknown error")" }
            let system = report.system
            if system.bufferCount == 0 {
                return "no system-audio buffers delivered for this filter"
            }
            if system.level.isDigitalSilence {
                return "system-audio buffers delivered but every sample was zero — the filter matched processes that produced no audio"
            }
            return "system audio delivered with signal (\(system.level.described))"
        }
    }

    static func capture(
        label: String,
        scope: CaptureScope,
        seconds: Double,
        microphoneDeviceID: String?,
        directory: URL,
        screenConsumer: ScreenConsumer = .none
    ) async -> Outcome {
        let options = RecordOptions(
            outputDirectory: directory,
            scope: scope,
            microphoneDeviceID: microphoneDeviceID,
            durationSeconds: seconds,
            sampleRate: 48_000,
            channelCount: 2,
            screenConsumer: screenConsumer,
            fallbackToMinimalScreen: false,
            startTimeoutSeconds: 0,
            segmentSeconds: 0,
            cpuSampleSeconds: 0,
            watchProcessName: "replayd"
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let journal = try JournalWriter(directory: directory)
            defer { journal.synchronizeAndClose() }
            journal.appendEvent([
                "record": "session-start",
                "tool": "capture-harness probe",
                "variant": label,
                "scope": scope.describedScope,
                "durationSeconds": seconds,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            ])
            let session = CaptureSession(options: options, journal: journal)
            try await session.start()
            let reason = await session.waitForStop()
            let report = await session.stop(reason: reason)
            let manifest = try JSONSerialization.data(
                withJSONObject: report.manifest,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try manifest.write(to: directory.appendingPathComponent("session.json"))
            return Outcome(label: label, scope: scope.describedScope, directory: directory, report: report, failure: nil)
        } catch {
            return Outcome(label: label, scope: scope.describedScope, directory: directory, report: nil, failure: error.localizedDescription)
        }
    }
}
