import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ArgumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            guard token.hasPrefix("--") else { throw ArgumentError(message: "Unexpected argument \(token)") }
            let name = String(token.dropFirst(2))
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[name] = raw[index + 1]
                index += 2
            } else {
                flags.insert(name)
                index += 1
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func string(_ name: String) -> String? { values[name] }

    func double(_ name: String, default fallback: Double) throws -> Double {
        guard let raw = values[name] else { return fallback }
        guard let value = Double(raw) else { throw ArgumentError(message: "--\(name) expects a number, got \(raw)") }
        return value
    }

    func int(_ name: String, default fallback: Int) throws -> Int {
        guard let raw = values[name] else { return fallback }
        guard let value = Int(raw) else { throw ArgumentError(message: "--\(name) expects an integer, got \(raw)") }
        return value
    }
}

enum RecordCommand {
    static func run(_ raw: [String]) async -> Int32 {
        do {
            let arguments = try Arguments(raw)
            let options = try makeOptions(arguments)
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

            let journal = try JournalWriter(directory: options.outputDirectory)
            defer { journal.synchronizeAndClose() }
            journal.appendEvent([
                "record": "session-start",
                "scope": options.scope.describedScope,
                "requestedScreenConsumer": options.screenConsumer.rawValue,
                "durationSeconds": options.durationSeconds,
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "commandLine": CommandLine.arguments.joined(separator: " "),
            ])

            let session = CaptureSession(options: options, journal: journal)
            print("Recording to \(options.outputDirectory.path)")
            print("Scope: \(options.scope.describedScope); screen consumer: \(options.screenConsumer.rawValue)")
            try await session.start()
            print("Stream started. Press Ctrl-C to stop early.")

            var reason = await session.waitForStop()
            if reason == .noAudioBeforeTimeout, options.fallbackToMinimalScreen, options.screenConsumer == .none {
                print("No audio arrived within \(options.startTimeoutSeconds) s without a screen consumer. Retrying with a minimal 2x2, 1 fps screen output.")
                try await session.retryWithMinimalScreen()
                reason = await session.waitForStop()
            }

            let report = await session.stop(reason: reason)
            let manifestURL = options.outputDirectory.appendingPathComponent("session.json")
            let manifest = try JSONSerialization.data(withJSONObject: report.manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try manifest.write(to: manifestURL)

            print("\n" + report.humanSummary)
            print("\nJournal: \(journal.timelineURL.path)")
            print("Events:  \(journal.eventsURL.path)")
            print("Manifest: \(manifestURL.path)")
            print("Next: capture-harness inspect \(journal.timelineURL.path)")
            return report.streamErrorMessage == nil ? 0 : 1
        } catch {
            fputs("capture-harness record: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func makeOptions(_ arguments: Arguments) throws -> RecordOptions {
        let bundleIdentifier = arguments.string("bundle-id")
        let allSystemAudio = arguments.flag("all-system-audio")
        guard bundleIdentifier != nil || allSystemAudio else {
            throw ArgumentError(message: "Pass --bundle-id <identifier> or --all-system-audio. The harness never chooses a source for you.")
        }
        guard !(bundleIdentifier != nil && allSystemAudio) else {
            throw ArgumentError(message: "--bundle-id and --all-system-audio are mutually exclusive.")
        }
        let scope: CaptureScope = bundleIdentifier.map { .application(bundleIdentifier: $0) } ?? .allSystemAudio

        let screenConsumer: ScreenConsumer
        switch arguments.string("screen-consumer") ?? "none" {
        case "none": screenConsumer = .none
        case "minimal": screenConsumer = .minimal
        case let other: throw ArgumentError(message: "--screen-consumer expects none or minimal, got \(other)")
        }

        let directory: URL
        if let path = arguments.string("output") {
            directory = URL(fileURLWithPath: path)
        } else {
            let stamp = Timestamp.sessionStamp()
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("captures")
                .appendingPathComponent(stamp)
        }

        return RecordOptions(
            outputDirectory: directory,
            scope: scope,
            microphoneDeviceID: arguments.string("microphone-uid"),
            durationSeconds: try arguments.double("duration", default: 300),
            sampleRate: try arguments.int("sample-rate", default: 48_000),
            channelCount: try arguments.int("channels", default: 2),
            screenConsumer: screenConsumer,
            fallbackToMinimalScreen: !arguments.flag("no-screen-fallback"),
            startTimeoutSeconds: try arguments.double("start-timeout", default: 15),
            segmentSeconds: try arguments.double("segment-seconds", default: 0),
            cpuSampleSeconds: try arguments.double("cpu-sample-seconds", default: 5),
            watchProcessName: arguments.string("watch-process") ?? "replayd"
        )
    }
}

enum DevicesCommand {
    static func run() async -> Int32 {
        print("Microphones (use the uid with --microphone-uid):")
        for device in MicrophoneCatalog.devices() {
            print("  \(device.localizedName) — uid \(device.uniqueID)")
        }
        if let fallback = AVCaptureDevice.default(for: .audio) {
            print("  default input: \(fallback.localizedName) — uid \(fallback.uniqueID)")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            print("\nDisplays: \(content.displays.map { "\($0.displayID) \($0.width)x\($0.height)" }.joined(separator: ", "))")
            print("Running applications (use the bundle identifier with --bundle-id):")
            let sorted = content.applications.sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            for application in sorted where !application.bundleIdentifier.isEmpty {
                print("  \(application.bundleIdentifier) — \(application.applicationName) (pid \(application.processID))")
            }
        } catch {
            fputs("Cannot read shareable content: \(error.localizedDescription)\n", stderr)
            fputs("Grant Screen & System Audio Recording to this binary first; see capture-harness permissions.\n", stderr)
            return 1
        }
        return 0
    }
}

enum PermissionsCommand {
    static func run(request: Bool) async -> Int32 {
        let screenGranted = CGPreflightScreenCaptureAccess()
        print("Screen & System Audio Recording: \(screenGranted ? "granted" : "not granted")")
        if !screenGranted && request {
            let requested = CGRequestScreenCaptureAccess()
            print("  requested; system responded granted=\(requested). macOS may require quitting and relaunching this binary.")
        }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Microphone: \(describe(microphoneStatus))")
        if microphoneStatus == .notDetermined && request {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("  requested; granted=\(granted)")
        }

        print("\nBinary: \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        print("Both permissions are keyed to this binary's code signature. Re-sign after every rebuild with Scripts/build-signed.sh,")
        print("and re-approve if the entry disappears from System Settings.")
        return screenGranted ? 0 : 1
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied — clear it in System Settings > Privacy & Security > Microphone"
        case .restricted: return "restricted by policy"
        case .notDetermined: return "not determined — run capture-harness permissions --request"
        @unknown default: return "unknown"
        }
    }
}
