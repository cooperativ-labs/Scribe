import Capture
import Foundation
import Platform
import ScribeAppCore
import Storage

/// The real-Mac integration gate for the recorder's capture core.
///
/// It drives the *shipping* `PermissionService`, `CaptureService` and
/// `SessionStore` -- not a copy of them -- for a configurable duration, then
/// checks the exit criteria for IMPLEMENTATION_PLAN.md section 3: both tracks
/// present, no dropped buffers, and a session store that holds real audio.
///
/// It has to run from an application bundle. A bare Mach-O executable cannot be
/// granted Screen & System Audio Recording by any route: `CGRequestScreenCaptureAccess`
/// returns false with no prompt, the System Settings **+** picker only accepts
/// bundles, and `tccutil` cannot address a client with no LaunchServices identity.
/// `Scripts/build-signed.sh` produces the bundle; see
/// docs/feasibility/capture-permissions.md.

struct Options {
    var bundleIdentifier: String?
    var microphoneUniqueID: String?
    var seconds: Double = 600
    var outputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("scribe-capture-integration", isDirectory: true)
    var requestPermissions = false
    /// How long the `flow` gate waits for background processing after capture
    /// closes. Cleanup is bounded by session length, not by a fixed budget.
    var processingTimeout: Double = 300
}

func usage() -> Never {
    let text = """
    capture-integration -- the real-Mac gate for CaptureService + SessionStore.

    USAGE
      capture-integration permissions [--request]
      capture-integration record --bundle-id <id> [--seconds 600] [--microphone <uid>] [--output <dir>]
      capture-integration flow   --bundle-id <id> [--seconds 20] [--microphone <uid>] [--output <dir>]
                                 [--processing-timeout 300]

    The `flow` gate drives the shipping menu-bar path end to end -- start, stop,
    process, open folder -- and checks that a verified transcription request is
    emitted for final.flac with the session ID as provenance.

    The `record` gate passes only when both tracks delivered audio and no buffer
    was dropped. Run it from the signed bundle:

      Scripts/build-signed.sh
      bin/CaptureIntegration.app/Contents/MacOS/capture-integration permissions --request
      bin/CaptureIntegration.app/Contents/MacOS/capture-integration record --bundle-id com.apple.Safari

    A rebuild changes the ad-hoc signature's cdhash and silently invalidates an
    earlier grant, so re-check `permissions` after every build.
    """
    print(text)
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        func value() -> String {
            guard index < arguments.count else { usage() }
            defer { index += 1 }
            return arguments[index]
        }
        switch argument {
        case "--bundle-id": options.bundleIdentifier = value()
        case "--microphone": options.microphoneUniqueID = value()
        case "--seconds": options.seconds = Double(value()) ?? 600
        case "--output": options.outputDirectory = URL(fileURLWithPath: value())
        case "--request": options.requestPermissions = true
        case "--processing-timeout": options.processingTimeout = Double(value()) ?? 300
        default: usage()
        }
    }
    return options
}

/// Reports both permissions, and requests whatever can still be requested.
func reportPermissions(request: Bool) async -> PermissionSnapshot {
    let service = PermissionService()
    let snapshot = request ? await service.requestMissingPermissions() : service.currentStatus()
    print("Screen & System Audio Recording: \(snapshot.screenAndSystemAudio.rawValue)")
    print("Microphone: \(snapshot.microphone.rawValue)")
    for requirement in snapshot.blockingRequirements {
        print("  blocked: \(requirement.message)")
        print("  route:   \(requirement.settingsURL.absoluteString)")
        print("  in-app request still possible: \(requirement.canRequestInApp)")
    }
    print("Binary: \(Bundle.main.executablePath ?? CommandLine.arguments[0])")
    return snapshot
}

/// Serializes the capture callbacks' events so the summary is written once, from
/// one place, after the stream has stopped.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var storeErrors: [String] = []
    private var cleanStopRequested = false
    private var streamFailure: String?

    func note(_ text: String) {
        lock.withLock { events.append(text) }
        FileHandle.standardError.write(Data(("  " + text + "\n").utf8))
    }

    func noteStoreError(_ error: Error) {
        lock.withLock { storeErrors.append(error.localizedDescription) }
    }

    func requestCleanStop() { lock.withLock { cleanStopRequested = true } }

    /// A dead stream keeps the wall clock running while delivering nothing, so the
    /// run has to end here rather than counting silence towards the duration.
    func noteStreamFailure(_ message: String) { lock.withLock { streamFailure = streamFailure ?? message } }

    var shouldStop: Bool { lock.withLock { cleanStopRequested || streamFailure != nil } }

    var summary: (events: [String], storeErrors: [String], cleanStopRequested: Bool, streamFailure: String?) {
        lock.withLock { (events, storeErrors, cleanStopRequested, streamFailure) }
    }
}

func record(_ options: Options) async -> Int32 {
    guard let bundleIdentifier = options.bundleIdentifier else { usage() }

    let permissions = await reportPermissions(request: false)
    guard permissions.isReadyToRecord else {
        // The exit criterion's second half: a missing or revoked permission has to
        // arrive as something a person can act on.
        if let failure = permissions.blockingFailure {
            print("\nFAIL \(failure.code): \(failure.message)")
            if let hint = failure.recoveryHint { print("     \(hint)") }
        }
        return 1
    }

    let recorder = Recorder()
    let store: SessionStore
    do {
        store = try SessionStore.create(configuration: SessionStoreConfiguration(
            recordingsDirectory: options.outputDirectory,
            appBuild: "capture-integration",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            captureScope: CaptureScope(applicationBundleIdentifiers: [bundleIdentifier], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: options.microphoneUniqueID ?? "default", name: "resolved at start"),
            cleanStopRequester: { recorder.requestCleanStop() }
        ))
    } catch {
        print("FAIL could not create the session store: \(error.localizedDescription)")
        return 1
    }
    print("\nSession directory: \(store.sessionDirectory.path)")

    let service = CaptureService(
        configuration: CaptureConfiguration(
            applicationBundleIdentifier: bundleIdentifier,
            microphoneUniqueID: options.microphoneUniqueID
        ),
        sink: { buffer in
            do { try store.append(buffer) } catch { recorder.noteStoreError(error) }
        },
        events: { event in
            switch event {
            case let .started(sources):
                recorder.note("started: \(sources.filterDescription); microphone \(sources.microphone.name)")
            case let .formatChanged(track, from, to):
                recorder.note("format change on \(track.rawValue): \(from.description) -> \(to.description)")
                try? store.recordInterruption(reason: "format change on \(track.rawValue)")
            case let .bufferRejected(track):
                recorder.note("rejected a buffer on \(track.rawValue)")
            case let .buffersDropped(track, count):
                recorder.note("DROPPED buffers on \(track.rawValue), running total \(count)")
            case let .streamFailed(failure):
                recorder.note("stream failed: \(failure.message)")
                recorder.noteStreamFailure(failure.message)
                try? store.recordInterruption(reason: failure.code)
            case .stopped:
                recorder.note("stopped")
            }
        }
    )

    do {
        let sources = try await service.start()
        print("Recording \(sources.applications.map(\.name).joined(separator: ", ")) "
            + "for \(Int(options.seconds))s into \(store.sessionDirectory.lastPathComponent)")
    } catch let error as CaptureServiceError {
        print("FAIL \(error.failure.code): \(error.failure.message)")
        if let hint = error.failure.recoveryHint { print("     \(hint)") }
        try? store.finish()
        return 1
    } catch {
        print("FAIL \(error.localizedDescription)")
        try? store.finish()
        return 1
    }

    let started = Date()
    while Date().timeIntervalSince(started) < options.seconds, !recorder.shouldStop {
        try? await Task.sleep(for: .seconds(1))
        let elapsed = Int(Date().timeIntervalSince(started))
        if elapsed > 0, elapsed.isMultiple(of: 60) {
            let statistics = service.statistics
            print("  \(elapsed)s: system \(statistics.system.enqueuedBuffers) buffers, "
                + "microphone \(statistics.microphone.enqueuedBuffers) buffers, "
                + "dropped \(statistics.droppedBuffers), peak queued "
                + "\(max(statistics.system.peakQueuedBytes, statistics.microphone.peakQueuedBytes)) bytes")
        }
    }

    let statistics = await service.stop()
    do { try store.finish() } catch { recorder.noteStoreError(error) }
    let summary = recorder.summary

    print("""

    Elapsed:            \(String(format: "%.1f", Date().timeIntervalSince(started)))s
    System buffers:     \(statistics.system.enqueuedBuffers)
    Microphone buffers: \(statistics.microphone.enqueuedBuffers)
    Dropped buffers:    \(statistics.droppedBuffers)
    Rejected buffers:   \(statistics.rejectedBuffers)
    Peak queued bytes:  \(max(statistics.system.peakQueuedBytes, statistics.microphone.peakQueuedBytes))
    Store errors:       \(summary.storeErrors.count)
    Session:            \(store.sessionDirectory.path)
    """)

    var failures: [String] = []
    if !statistics.hasBothTracks {
        failures.append("both tracks must deliver audio (system \(statistics.system.enqueuedBuffers), microphone \(statistics.microphone.enqueuedBuffers))")
    }
    if statistics.droppedBuffers > 0 { failures.append("\(statistics.droppedBuffers) buffers were dropped") }
    if let first = summary.storeErrors.first { failures.append("the session store reported \(summary.storeErrors.count) error(s): \(first)") }
    if summary.cleanStopRequested { failures.append("the store requested a clean stop before the free-space reserve") }
    if let streamFailure = summary.streamFailure {
        // A stream that has died still lets the wall clock run while it delivers
        // nothing, so a run that ends this way did not record for its full duration.
        failures.append("the stream failed after \(Int(Date().timeIntervalSince(started)))s of the requested \(Int(options.seconds))s: \(streamFailure)")
    }

    let segments = (try? FileManager.default.contentsOfDirectory(atPath: store.captureDirectory.path)) ?? []
    let cafFiles = segments.filter { $0.hasSuffix(".caf") }
    print("CAF segments:       \(cafFiles.count) (\(cafFiles.sorted().joined(separator: ", ")))")
    if !cafFiles.contains(where: { $0.hasPrefix("system") }) { failures.append("no system CAF segment was written") }
    if !cafFiles.contains(where: { $0.hasPrefix("microphone") }) { failures.append("no microphone CAF segment was written") }

    // Silence is valid input and is never used to judge a capture; the gate is
    // buffer delivery, timestamps and files, exactly as section 3 requires.
    guard failures.isEmpty else {
        print("\nFAIL")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
    print("\nPASS")
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let options = parse(Array(arguments.dropFirst()))

switch command {
case "permissions":
    let snapshot = await reportPermissions(request: options.requestPermissions)
    exit(snapshot.isReadyToRecord ? 0 : 1)
case "record":
    exit(await record(options))
case "flow":
    exit(await runFlow(options))
default:
    usage()
}
