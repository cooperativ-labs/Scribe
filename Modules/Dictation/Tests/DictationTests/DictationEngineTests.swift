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

    // Uses real process arguments and pipes, but no model files or microphone.
    // Returning the process ID as text lets the test observe worker reuse.
    private static let workerScript = #"""
    #!/bin/sh
    set -eu
    printf '%s\n' "$@" >> "$(dirname "$0")/arguments"
    while IFS= read -r line; do
        rid=$(printf '%s' "$line" | sed -n 's/.*"requestID":"\([^"]*\)".*/\1/p')
        operation=$(printf '%s' "$line" | sed -n 's/.*"operation":"\([^"]*\)".*/\1/p')
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
