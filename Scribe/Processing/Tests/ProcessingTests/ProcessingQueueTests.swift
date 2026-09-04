import Foundation
import ScribeAppCore
import Testing
@testable import Processing

@Test func pendingJobsPersistAndAreDeferredWhileCaptureIsActive() async throws {
    let root = try queueTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let id = UUID()
    let configuration = ProcessingQueue.Configuration.inRecordingsDirectory(root)
    let queue = try ProcessingQueue(configuration: configuration)

    await queue.setCaptureActive(true)
    #expect(try await queue.enqueue(sessionDirectory: session, jobID: id) == .deferUntilCaptureEnds)
    #expect(await queue.isCaptureActive())

    let reloaded = try ProcessingQueue(configuration: configuration)
    #expect(await reloaded.pendingJobs() == [.init(id: id, sessionDirectory: session)])
}

@Test func recoveryTurnsInterruptedRunningWorkBackIntoPendingWork() async throws {
    let root = try queueTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("recover-me", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let id = UUID()
    try AtomicReplaceFileWriter().write(queueManifest(id: id, processing: .running), to: session.appendingPathComponent("metadata.json"))

    let queue = try ProcessingQueue(configuration: .inRecordingsDirectory(root))
    let recovered = try await queue.recoverSessions(in: root)
    #expect(recovered.map(\.id) == [id])
    #expect(recovered.first?.sessionDirectory.resolvingSymlinksInPath().path == session.resolvingSymlinksInPath().path)

    let manifest = try RecorderSessionManifestCodec.decode(Data(contentsOf: session.appendingPathComponent("metadata.json")))
    #expect(manifest.processing.state == .pending)
}

private func queueTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeProcessingQueueTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func queueManifest(id: UUID, processing: ProcessingState) -> RecorderSessionManifest {
    RecorderSessionManifest(
        sessionID: id,
        appBuild: "tests",
        macOSVersion: "tests",
        startedAt: Date(timeIntervalSince1970: 0),
        completionStatus: .complete,
        capture: CaptureMetadata(
            state: .complete,
            scope: CaptureScope(applicationBundleIdentifiers: [], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "test", name: "Test")
        ),
        tracks: RecorderTrackCollection(),
        processing: ProcessingMetadata(state: processing)
    )
}
