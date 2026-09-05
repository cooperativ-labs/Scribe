import Foundation
import ScribeAppCore
import Testing
@testable import Processing

/// The whole tail of the recorder flow: a finished capture goes into the queue,
/// comes out as a published `final.flac`, and only then becomes a transcription
/// request. These run the real processor and the real checksum, because the
/// point of the handoff is that nothing along here is taken on trust.
@Suite("Processing queue handoff") struct ProcessingQueueHandoffTests {
    @Test func aProcessedSessionReportsCompletionAndBecomesAVerifiedTranscriptionRequest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let session = try handoffCaptureSession(root: root, sessionID: sessionID, seconds: 0.75)

        let queue = try ProcessingQueue(configuration: .inRecordingsDirectory(root))
        let events = QueueEventRecorder(await queue.events())
        _ = try await queue.enqueue(sessionDirectory: session, jobID: sessionID)
        await queue.runPending()

        #expect(await events.kindsAfterTerminalEvent() == ["queued", "started", "completed"])
        #expect(await queue.pendingJobs().isEmpty)

        // The real gate, with the real hash, over the file the pipeline published.
        let request = try FinalRecordingHandoff().request(forSessionAt: session)
        #expect(request.sourceURL == session.appendingPathComponent("final.flac"))
        #expect(request.provenance?.sessionID == sessionID)
        #expect(request.provenance?.producerID == FinalRecordingHandoff.producerID)
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("system.flac").path))
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("microphone.flac").path))

        let manifest = try RecorderSessionManifestCodec.decode(
            Data(contentsOf: session.appendingPathComponent("metadata.json"))
        )
        #expect(manifest.tracks.system == nil)
        #expect(manifest.tracks.microphone == nil)
        #expect(manifest.tracks.finalTrack != nil)

        let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        try await outbox.submit(request)
        #expect(try await outbox.pendingRequests() == [request])
    }

    @Test func aFailedJobReportsFailureAndTheSessionNeverReachesTranscription() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A manifest with no capture archive behind it: the pipeline has nothing
        // to reconstruct, so cleanup fails with the originals question moot.
        let session = root.appendingPathComponent("no-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let sessionID = UUID()
        try AtomicReplaceFileWriter().write(
            handoffManifest(sessionID: sessionID, processing: .pending),
            to: session.appendingPathComponent("metadata.json")
        )

        let queue = try ProcessingQueue(configuration: .inRecordingsDirectory(root))
        let events = QueueEventRecorder(await queue.events())
        _ = try await queue.enqueue(sessionDirectory: session, jobID: sessionID)
        await queue.runPending()

        #expect(await events.kindsAfterTerminalEvent() == ["queued", "started", "failed"])
        #expect(await events.failureMessage()?.isEmpty == false)
        // Failed work leaves the automatic queue; a rerun is an explicit choice.
        #expect(await queue.pendingJobs().isEmpty)

        let manifest = try RecorderSessionManifestCodec.decode(
            Data(contentsOf: session.appendingPathComponent("metadata.json"))
        )
        #expect(manifest.processing.state == .failed)
        do {
            _ = try FinalRecordingHandoff().request(forSessionAt: session)
            Issue.record("A session whose cleanup failed must never be handed off")
        } catch let refusal as FinalRecordingHandoffRefusal {
            guard case .cleanupFailed = refusal else {
                Issue.record("Expected a cleanup failure, got \(refusal)")
                return
            }
        }
    }
}

// MARK: - Support

/// Collects queue events off the actor so a test can assert the whole sequence
/// rather than only the final state.
private actor QueueEventRecorder {
    private var events: [ProcessingQueue.Event] = []
    /// Delivery is asynchronous, so a test waits for the job's terminal event
    /// rather than sampling whatever had arrived by the time the queue returned.
    private var waitingForTerminal: CheckedContinuation<Void, Never>?

    init(_ stream: AsyncStream<ProcessingQueue.Event>) {
        Task { for await event in stream { await self.record(event) } }
    }

    private func record(_ event: ProcessingQueue.Event) {
        events.append(event)
        switch event {
        case .completed, .failed:
            waitingForTerminal?.resume()
            waitingForTerminal = nil
        case .queued, .started:
            break
        }
    }

    func kindsAfterTerminalEvent() async -> [String] {
        let hasTerminal = events.contains { event in
            switch event {
            case .completed, .failed: true
            case .queued, .started: false
            }
        }
        if !hasTerminal { await withCheckedContinuation { waitingForTerminal = $0 } }
        return kinds()
    }

    private func kinds() -> [String] {
        events.map { event in
            switch event {
            case .queued: "queued"
            case .started: "started"
            case .completed: "completed"
            case .failed: "failed"
            }
        }
    }

    func failureMessage() -> String? {
        for event in events { if case .failed(_, let message) = event { return message } }
        return nil
    }
}

/// A minimal but genuine capture archive: two mono 48 kHz tracks on one timeline,
/// enough for the exporter and the mixdown to produce a real `final.flac`.
private func handoffCaptureSession(root: URL, sessionID: UUID, seconds: Double) throws -> URL {
    let sampleRate = 48_000
    let frames = Int(seconds * Double(sampleRate))
    let archive = try CaptureArchiveFixture(root: root, name: "2026-09-04 09-00-00")
    let format = CaptureArchiveFixture.Format(sampleRate: sampleRate, channelCount: 1)
    let system = testSignal(frames: frames)
    let microphone = testSignal(frames: frames, startingAt: 1_000_003)

    var frame = 0
    while frame < frames {
        let count = min(480, frames - frame)
        let at = 1_000 + Double(frame) / Double(sampleRate)
        try archive.write(track: "system", at: at, samples: Array(system[frame..<(frame + count)]), format: format)
        try archive.write(track: "microphone", at: at, samples: Array(microphone[frame..<(frame + count)]), format: format)
        frame += count
    }
    try archive.finish()
    try AtomicReplaceFileWriter().write(
        handoffManifest(sessionID: sessionID, processing: .pending),
        to: archive.sessionDirectory.appendingPathComponent("metadata.json")
    )
    return archive.sessionDirectory
}

private func handoffManifest(sessionID: UUID, processing: ProcessingState) -> RecorderSessionManifest {
    RecorderSessionManifest(
        sessionID: sessionID,
        appBuild: "tests",
        macOSVersion: "tests",
        startedAt: Date(timeIntervalSince1970: 0),
        completionStatus: .complete,
        capture: CaptureMetadata(
            state: .complete,
            scope: CaptureScope(applicationBundleIdentifiers: ["com.example.meeting"], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "test", name: "Test Microphone")
        ),
        tracks: RecorderTrackCollection(),
        processing: ProcessingMetadata(state: processing)
    )
}
