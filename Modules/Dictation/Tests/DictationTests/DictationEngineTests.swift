import Foundation
import Platform
import Transcription
import XCTest
@testable import Dictation

final class DictationEngineTests: XCTestCase {
    @MainActor
    func testWorkerUsesSettingsFolderAndReloadsWhenItChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "worker")
        try Self.workerScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let selection = ModelFolderSelection(directory: ScribeSettings.defaultModelsFolderURL)
        let manifest = root.appending(path: "model_manifest.json")
        let engine = DictationEngine(
            installation: WorkerInstallation(
                executableURL: executable, manifestURL: manifest,
                modelsDirectoryURL: URL(fileURLWithPath: "/models")
            ),
            modelsDirectoryProvider: { @MainActor in selection.directory }
        )
        do {
            try await engine.warm()
            let first = try await engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            let reused = try await engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            XCTAssertEqual(first.text, reused.text, "Unchanged settings should reuse the resident helper")

            let customFolder = root.appending(path: "Custom Models ü", directoryHint: .isDirectory)
            selection.directory = customFolder
            let changed = try await engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            XCTAssertNotEqual(first.text, changed.text, "A new folder requires a new helper")
            // Concurrent preview/final calls must not consume each other's
            // response envelopes or deadlock the resident worker.
            async let preview = engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            async let final = engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            let results = try await (preview, final)
            XCTAssertEqual(results.0.text, changed.text)
            XCTAssertEqual(results.1.text, changed.text)
            let cancelled = Task { () throws -> DictationTranscript in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            }
            do { _ = try await cancelled.value; XCTFail("Cancelled requests must not reach the worker") }
            catch is CancellationError { }
            let afterCancel = try await engine.dictate(audioURL: root.appending(path: "audio.wav"), runDirectoryURL: root)
            XCTAssertEqual(afterCancel.text, changed.text)
            await engine.unload()

            let arguments = try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(arguments, [
                "--manifest", manifest.path, "--models-directory", ScribeSettings.defaultModelsFolderURL.path,
                "--mode", "dictation",
                "--manifest", manifest.path, "--models-directory", customFolder.path,
                "--mode", "dictation",
            ])
        } catch {
            await engine.unload()
            throw error
        }
    }

    /// An unload that lands while a request is loading the model must not throw
    /// that request away after the wait; it applies once the request is done.
    @MainActor
    func testUnloadDuringARequestWaitsForIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = fixture.makeEngine()
        try fixture.slow("warm")
        let request = Task { try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root) }
        try await Task.sleep(for: .milliseconds(200))
        await engine.unload()
        let result = try await request.value
        XCTAssertFalse(result.text.isEmpty, "The request that was warming must still be answered")
        let ready = await engine.isReady()
        XCTAssertFalse(ready, "The deferred unload applies once the request has finished")
    }

    /// The person's ✕ abandons the result; the helper it took so long to warm
    /// stays for the next dictation.
    @MainActor
    func testCancellingARequestKeepsTheWarmHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = fixture.makeEngine()
        let first = try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root)
        try fixture.slow("dictate")
        let cancelled = Task { try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled request must not deliver a result") }
        catch is CancellationError {}
        try fixture.fast("dictate")
        let next = try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root)
        XCTAssertEqual(next.text, first.text, "The same helper process answers after a cancel")
        await engine.unload()
    }

    /// Readiness is what the indicator uses to say "Loading model…" instead of
    /// "Transcribing…" during a cold start.
    @MainActor
    func testReadinessFollowsTheHelperLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = fixture.makeEngine()
        var ready = await engine.isReady()
        XCTAssertFalse(ready)
        try await engine.warm()
        ready = await engine.isReady()
        XCTAssertTrue(ready)
        await engine.unload()
        ready = await engine.isReady()
        XCTAssertFalse(ready)
    }

    /// A memory warning keeps a helper the person asked to keep; critical
    /// pressure releases it regardless.
    @MainActor
    func testMemoryPressureRespectsKeepLoaded() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = fixture.makeEngine()
        await engine.configure(keepLoaded: true, idleMinutes: 10)
        try await engine.warm()
        await engine.memoryPressureChanged(critical: false)
        var ready = await engine.isReady()
        XCTAssertTrue(ready, "A warning must not discard a helper that is meant to stay loaded")
        await engine.memoryPressureChanged(critical: true)
        ready = await engine.isReady()
        XCTAssertFalse(ready, "Critical pressure releases the helper")

        await engine.configure(keepLoaded: false, idleMinutes: 10)
        try await engine.warm()
        await engine.memoryPressureChanged(critical: false)
        ready = await engine.isReady()
        XCTAssertFalse(ready, "Without keep-loaded a warning releases the helper")
    }

    /// A request that arrives while the old helper is being told to unload gets
    /// a fresh helper rather than sharing the departing one's channel.
    @MainActor
    func testARequestDuringAnUnloadGetsAFreshHelper() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let engine = fixture.makeEngine()
        let first = try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root)
        try fixture.slow("unload")
        let unloading = Task { await engine.unload() }
        try await Task.sleep(for: .milliseconds(100))
        let next = try await engine.dictate(audioURL: fixture.audio, runDirectoryURL: fixture.root)
        await unloading.value
        XCTAssertNotEqual(next.text, first.text, "A new helper answers while the old one leaves")
        await engine.unload()
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let audio: URL
        private let executable: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            audio = root.appending(path: "audio.wav")
            executable = root.appending(path: "worker")
            try DictationEngineTests.workerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        func makeEngine() -> DictationEngine {
            let directory = ScribeSettings.defaultModelsFolderURL
            return DictationEngine(
                installation: WorkerInstallation(executableURL: executable, manifestURL: root.appending(path: "model_manifest.json")),
                modelsDirectoryProvider: { directory }
            )
        }

        func slow(_ operation: String) throws {
            try Data().write(to: root.appending(path: "slow-\(operation)"))
        }

        func fast(_ operation: String) throws {
            try FileManager.default.removeItem(at: root.appending(path: "slow-\(operation)"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    // Uses real process arguments and pipes, but no model files or microphone.
    // Returning the process ID as text lets the test observe worker reuse.
    private static let workerScript = #"""
    #!/bin/sh
    set -eu
    printf '%s\n' "$@" >> "$(dirname "$0")/arguments"
    while IFS= read -r line; do
        rid=$(printf '%s' "$line" | sed -n 's/.*"requestID":"\([^"]*\)".*/\1/p')
        operation=$(printf '%s' "$line" | sed -n 's/.*"operation":"\([^"]*\)".*/\1/p')
        # A marker file beside the script makes that operation slow, standing
        # in for a model load or a long inference.
        if [ -f "$(dirname "$0")/slow-$operation" ]; then sleep 1; fi
        if [ "$operation" = handshake ]; then
            printf '{"version":2,"kind":"stage_result","requestID":"%s","payload":{"stage":"handshake","protocolVersion":2,"networking":"disabled","runtimeDownloads":false,"telemetry":false}}\n' "$rid"
        else
            printf '{"version":2,"kind":"stage_result","requestID":"%s","payload":{"stage":"%s","status":"complete","text":"%s"}}\n' "$rid" "$operation" "$$"
        fi
    done
    """#
}

@MainActor
private final class ModelFolderSelection {
    var directory: URL
    init(directory: URL) { self.directory = directory }
}
