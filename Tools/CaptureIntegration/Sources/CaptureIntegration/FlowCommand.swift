import AppKit
import Capture
import Foundation
import Platform
import Processing
import ScribeAppCore

/// The real-Mac gate for IMPLEMENTATION_PLAN.md section 6 and milestone 4: the
/// complete start → stop → process → open-folder flow, plus the transcription
/// handoff, driven through the *shipping* menu-bar path.
///
/// It uses `LiveRecordingCoordinator`, `ProcessingQueue`, `FinalRecordingHandoff`
/// and `TranscriptionRequestOutbox` exactly as `ScribeAppEnvironment` wires them,
/// and submits the same `RecordingCommand` values the menu and the global
/// shortcuts submit. Nothing here is a reimplementation of the app's behaviour;
/// if this passes, the menu-bar flow works.
///
/// Run it from the signed bundle, with a meeting application foregrounded and
/// producing audio. See README.md.
@MainActor
func runFlow(_ options: Options) async -> Int32 {
    guard let bundleIdentifier = options.bundleIdentifier else { usage() }
    let recordingsDirectory = options.outputDirectory
    try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

    let permissions = PermissionService()
    let queue: ProcessingQueue
    do {
        queue = try ProcessingQueue(configuration: .inRecordingsDirectory(recordingsDirectory))
    } catch {
        print("FAIL could not open the processing queue: \(error.localizedDescription)")
        return 1
    }
    let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(recordingsDirectory)
    let observer = FlowObserver()

    let coordinator = LiveRecordingCoordinator(
        snapshot: RecorderSnapshot(
            permissions: permissions.currentStatus(),
            selectedApplicationID: bundleIdentifier,
            selectedMicrophoneID: options.microphoneUniqueID,
            recordingsFolderURL: recordingsDirectory
        ),
        permissions: permissions,
        openFolder: { url in
            observer.note("openRecordingsFolder -> \(url.path)")
            observer.openedFolder = url
        },
        scheduler: queue,
        processingSubmission: { directory, job in
            _ = try? await queue.enqueue(sessionDirectory: directory, jobID: job.id)
            await queue.runPending()
        },
        captureActivityHandler: { active in await queue.setCaptureActive(active) },
        appBuild: "capture-integration",
        macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
    coordinator.recoveryReporter = { recovered in
        observer.note("launch recovery repaired \(recovered.count) session(s)")
    }

    let queueEventStream = await queue.events()
    let queueEvents = Task { [observer] in
        for await event in queueEventStream { observer.record(event) }
    }
    defer { queueEvents.cancel() }

    let snapshotObservation = coordinator.observeSnapshot { snapshot in
        observer.record(snapshot)
    }
    defer { snapshotObservation.invalidate() }

    // Exactly the command the menu's Start Recording button and the global start
    // shortcut submit — not a private entry point.
    print("Starting a \(Int(options.seconds))s capture of \(bundleIdentifier)…")
    coordinator.submit(.start)
    try? await Task.sleep(for: .seconds(2))

    guard case .recording(let activity) = coordinator.snapshot.state else {
        print("\nFAIL the recorder did not enter Recording; state is \(coordinator.snapshot.state)")
        if case .failed(let failure) = coordinator.snapshot.state {
            print("     \(failure.code): \(failure.message)")
            if let hint = failure.recoveryHint { print("     \(hint)") }
        }
        return 1
    }
    print("Recording session \(activity.sessionID)")

    let started = Date()
    while Date().timeIntervalSince(started) < options.seconds, coordinator.snapshot.state.isRecording {
        try? await Task.sleep(for: .seconds(1))
    }

    coordinator.submit(.stop)
    // A stop that has drained returns the recorder to Idle. This is also the
    // property quitting during capture depends on.
    try? await Task.sleep(for: .seconds(3))

    var failures: [String] = []
    if coordinator.snapshot.state != .idle {
        failures.append("the recorder did not return to Idle after Stop; state is \(coordinator.snapshot.state)")
    }
    if !observer.sawRecordingState { failures.append("no Recording state was ever published to the menu") }

    // Background processing runs after capture has closed, which is the whole
    // reason it is reported separately: the recorder is startable again now.
    if !coordinator.snapshot.state.isRecording, !coordinator.snapshot.permissions.isReadyToRecord {
        failures.append("permissions became not-ready during the run")
    }
    print("Waiting for background processing…")
    let processingDeadline = Date().addingTimeInterval(options.processingTimeout)
    while Date() < processingDeadline, !observer.processingFinished {
        try? await Task.sleep(for: .seconds(1))
    }

    guard let sessionDirectory = observer.processedSessionDirectory else {
        failures.append("background processing did not finish within \(Int(options.processingTimeout))s")
        return report(failures: failures, observer: observer)
    }
    if let message = observer.processingFailure {
        failures.append("processing failed: \(message)")
        return report(failures: failures, observer: observer)
    }

    // Open Recordings Folder, through the same serialized command path.
    coordinator.submit(.openRecordingsFolder)
    try? await Task.sleep(for: .seconds(1))
    if observer.openedFolder?.standardizedFileURL != recordingsDirectory.standardizedFileURL {
        failures.append("Open Recordings Folder did not resolve to the recordings folder")
    }

    // The handoff, verified rather than assumed: a request exists only if
    // final.flac was published and its checksum matches the manifest.
    do {
        let request = try FinalRecordingHandoff().request(forSessionAt: sessionDirectory)
        try await outbox.submit(request)
        guard let provenance = request.provenance else {
            failures.append("the transcription request carries no provenance")
            return report(failures: failures, observer: observer)
        }
        if provenance.sessionID != activity.sessionID {
            failures.append("provenance names session \(provenance.sessionID), not the recorded \(activity.sessionID)")
        }
        let pending = try await outbox.pendingRequests()
        if !pending.contains(where: { $0.requestID == request.requestID }) {
            failures.append("the transcription request was not durably handed off")
        }
        print("""

        Session:            \(sessionDirectory.path)
        final.flac:         \(request.sourceURL.lastPathComponent)
        Transcription:      \(request.requestID)
        Provenance:         \(provenance.producerID) / \(provenance.sessionID)
        Outbox entries:     \(pending.count)
        """)
    } catch let refusal as FinalRecordingHandoffRefusal {
        failures.append("the transcription handoff refused the session: \(refusal.message)")
    } catch {
        failures.append("the transcription handoff could not be submitted: \(error.localizedDescription)")
    }

    return report(failures: failures, observer: observer)
}

@MainActor
private func report(failures: [String], observer: FlowObserver) -> Int32 {
    print("\nMenu states seen:   \(observer.stateNames.joined(separator: " -> "))")
    print("Queue events:       \(observer.queueEventNames.joined(separator: " -> "))")
    for note in observer.notes { print("  \(note)") }
    guard failures.isEmpty else {
        print("\nFAIL")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
    print("\nPASS")
    return 0
}

/// Records what the menu would have shown and what the queue did, so a failure
/// says which step of the flow broke rather than only that it broke.
@MainActor
final class FlowObserver {
    private(set) var stateNames: [String] = []
    private(set) var queueEventNames: [String] = []
    private(set) var notes: [String] = []
    private(set) var processedSessionDirectory: URL?
    private(set) var processingFailure: String?
    private(set) var processingFinished = false
    private(set) var sawRecordingState = false
    var openedFolder: URL?

    func note(_ text: String) {
        notes.append(text)
        print("  \(text)")
    }

    func record(_ snapshot: RecorderSnapshot) {
        let name: String
        switch snapshot.state {
        case .idle: name = "Idle"
        case .starting: name = "Starting"
        case .recording: name = "Recording"; sawRecordingState = true
        case .stopping: name = "Stopping"
        case .failed(let failure): name = "Failed(\(failure.code))"
        }
        if stateNames.last != name { stateNames.append(name) }
        if let notice = snapshot.recoveryNotice, !notes.contains(notice) { note(notice) }
    }

    func record(_ event: ProcessingQueue.Event) {
        switch event {
        case .queued: queueEventNames.append("queued")
        case .started: queueEventNames.append("started")
        case .completed(let job):
            queueEventNames.append("completed")
            processedSessionDirectory = job.sessionDirectory
            processingFinished = true
        case .failed(_, let message):
            queueEventNames.append("failed")
            processingFailure = message
            processingFinished = true
        }
    }
}
