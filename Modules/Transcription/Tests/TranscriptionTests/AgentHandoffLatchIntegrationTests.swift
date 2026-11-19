import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// Hands a benign fixture to a real Latch session, exactly as the app does
/// (the same files, manifest and `latch create --manifest-file - --json`),
/// with a stand-in "agent" that only records what it was given.
///
/// Opt-in, because it needs Latch installed and starts a real session:
/// `SCRIBE_LATCH_INTEGRATION=1 swift test --filter AgentHandoffLatchIntegrationTests`.
/// `SCRIBE_LATCH_PATH` points at a `latch` other than `~/.local/bin/latch`.
final class AgentHandoffLatchIntegrationTests: XCTestCase {
    func testARealLatchSessionReceivesThePromptNotesAndTranscript() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SCRIBE_LATCH_INTEGRATION"] == "1", "Set SCRIBE_LATCH_INTEGRATION=1 to start a real Latch session.")
        let latchURL = URL(fileURLWithPath: environment["SCRIBE_LATCH_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/latch").path)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: latchURL.path), "latch is not installed at \(latchURL.path)")

        let root = FileManager.default.temporaryDirectory
            .appending(path: "scribe-latch-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        let handoffs = root.appending(path: "Agent Handoffs")
        let workFolder = root.appending(path: "work")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The stand-in agent writes down its last argument (the prompt) and
        // which handoff files it could read, then stays alive like an
        // interactive agent would.
        let agentScript = root.appending(path: "fixture-agent")
        try """
        #!/bin/sh
        for last in "$@"; do :; done
        printf '%s' "$last" > received-prompt.txt
        if [ -r "$SCRIBE_TRANSCRIPT_FILE" ]; then echo transcript-readable > received-files.txt; fi
        echo "Scribe fixture agent received the handoff."
        sleep 30
        """.write(to: agentScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentScript.path)

        let url = try XCTUnwrap(Bundle.module.url(forResource: "two-speakers", withExtension: "json"))
        let request = TranscriptAgentRequest(
            transcript: try CanonicalTranscriptCodec.decode(Data(contentsOf: url)),
            agent: TranscriptAgent(id: "fixture", displayName: "Fixture Agent", commandLabel: "fixture-agent"),
            folder: TranscriptAgentFolder(url: workFolder),
            instruction: "Reply with the word OK. Do not read, write or change anything.",
            notes: [
                MeetingNote(text: "Benign fixture note", recordingOffsetMilliseconds: 65_000),
                MeetingNote(text: "Untimed fixture note"),
            ]
        )

        let files = try AgentHandoffPayload.writeFiles(for: request, in: handoffs)
        let manifest = AgentHandoffPayload.manifest(for: request, executableURL: agentScript, files: files)
        let output = try run(latchURL, ["create", "--manifest-file", "-", "--json"], input: try manifest.encoded())
        let report = try LatchCreateReport.decode(output)
        defer { _ = try? run(latchURL, ["remove", "--force", report.session.id], input: nil) }

        let receivedURL = workFolder.appending(path: "received-prompt.txt")
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: receivedURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let received = try String(contentsOf: receivedURL, encoding: .utf8)

        XCTAssertEqual(received, AgentHandoffPayload.prompt(for: request, files: files))
        XCTAssertTrue(received.contains("[01:05] Benign fixture note"))
        XCTAssertTrue(received.contains("[--:--] Untimed fixture note"))
        XCTAssertTrue(received.contains(AgentHandoffPayload.untrustedTranscriptStatement))
        XCTAssertEqual(try String(contentsOf: workFolder.appending(path: "received-files.txt"), encoding: .utf8), "transcript-readable\n")
        XCTAssertEqual(files.transcriptURL.lastPathComponent, "\(request.operationID.uuidString).kb.json")
        let mode = try FileManager.default.attributesOfItem(atPath: files.transcriptURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let inspected = String(decoding: try run(latchURL, ["inspect", report.session.id, "--json"], input: nil), as: UTF8.self)
        XCTAssertTrue(inspected.contains(report.session.id))
        XCTAssertTrue(inspected.contains("scribe"), "the session records Scribe as its source")
    }

    /// Phase 4's crash case against a real Latch: Scribe is killed after
    /// `latch create` started the session and before the outcome was saved,
    /// then re-issues the same send under the same operation ID. Latch must
    /// answer with the first session, so exactly one exists. Runs in a
    /// throwaway `LATCH_HOME`, so no real session is touched.
    func testARealLatchStartsOneSessionPerOperationAcrossAKilledCreate() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SCRIBE_LATCH_INTEGRATION"] == "1", "Set SCRIBE_LATCH_INTEGRATION=1 to start a real Latch session.")
        let latchURL = URL(fileURLWithPath: environment["SCRIBE_LATCH_PATH"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/latch").path)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: latchURL.path), "latch is not installed at \(latchURL.path)")
        let capabilities = try LatchCapabilitiesReport.decode(run(latchURL, ["capabilities", "--json"], input: nil))
        try XCTSkipUnless(capabilities.capabilities.extensions.contains(LatchCapabilitiesReport.createRequestIDExtension), "this latch has no --request-id")

        let root = FileManager.default.temporaryDirectory
            .appending(path: "scribe-latch-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        let latchHome = root.appending(path: "latch-home")
        let workFolder = root.appending(path: "work")
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: latchHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agentScript = root.appending(path: "fixture-agent")
        try "#!/bin/sh\necho started >> starts.txt\nsleep 30\n".write(to: agentScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agentScript.path)

        let url = try XCTUnwrap(Bundle.module.url(forResource: "two-speakers", withExtension: "json"))
        let request = TranscriptAgentRequest(
            transcript: try CanonicalTranscriptCodec.decode(Data(contentsOf: url)),
            agent: TranscriptAgent(id: "fixture", displayName: "Fixture Agent", commandLabel: "fixture-agent"),
            folder: TranscriptAgentFolder(url: workFolder),
            instruction: "Reply with the word OK.",
            notes: [MeetingNote(text: "Benign fixture note", recordingOffsetMilliseconds: 1_000)],
            delivery: .background
        )
        let files = try AgentHandoffPayload.writeFiles(for: request, in: root.appending(path: "Agent Handoffs"))
        let payload = try AgentHandoffPayload.manifest(for: request, executableURL: agentScript, files: files).encoded()
        let requestID = request.operationID.uuidString.lowercased()
        let create = ["create", "--manifest-file", "-", "--json", "--request-id", requestID]
        let homeEnvironment = ["LATCH_HOME": latchHome.path]

        // First attempt: killed as soon as the session exists, before any
        // report is read, which is what a Scribe crash looks like to Latch.
        let first = try start(latchURL, create, input: payload, environment: homeEnvironment)
        let sessions = latchHome.appending(path: "sessions")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
            if found.contains(where: { FileManager.default.fileExists(atPath: sessions.appending(path: "\($0)/meta.json").path) }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        kill(first.process.processIdentifier, SIGKILL)
        first.process.waitUntilExit()

        // The relaunch re-issues the same send.
        let report = try LatchCreateReport.decode(run(latchURL, create, input: payload, environment: homeEnvironment))
        defer { _ = try? run(latchURL, ["remove", "--force", report.session.id], input: nil, environment: homeEnvironment) }
        XCTAssertEqual(report.reused, true, "Latch answered with the session the killed attempt started")

        // And once more, as a duplicate completion event would.
        let again = try LatchCreateReport.decode(run(latchURL, create, input: payload, environment: homeEnvironment))
        XCTAssertEqual(again.session.id, report.session.id)
        XCTAssertEqual(again.reused, true)

        let listed = try JSONSerialization.jsonObject(with: run(latchURL, ["list", "--json"], input: nil, environment: homeEnvironment)) as? [String: Any]
        XCTAssertEqual((listed?["sessions"] as? [Any])?.count, 1, "exactly one Latch session")

        // The same ID for a different send is refused, never a second launch.
        let other = TranscriptAgentRequest(
            operationID: request.operationID,
            transcript: request.transcript,
            agent: request.agent,
            folder: request.folder,
            instruction: "A different prompt."
        )
        let otherPayload = try AgentHandoffPayload.manifest(for: other, executableURL: agentScript, files: files).encoded()
        let refused = try start(latchURL, create, input: otherPayload, environment: homeEnvironment)
        let refusalOutput = refused.output.fileHandleForReading.readDataToEndOfFile()
        refused.process.waitUntilExit()
        XCTAssertEqual(refused.process.terminationStatus, 65)
        XCTAssertEqual(try LatchCreateErrorReport.decode(refusalOutput).error.code, "request_id_conflict")
        let afterRefusal = try JSONSerialization.jsonObject(with: run(latchURL, ["list", "--json"], input: nil, environment: homeEnvironment)) as? [String: Any]
        XCTAssertEqual((afterRefusal?["sessions"] as? [Any])?.count, 1)
    }

    /// Starts a `latch` command without waiting for it.
    private func start(_ executable: URL, _ arguments: [String], input: Data, environment extra: [String: String]) throws -> (process: Process, output: Pipe) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "LATCH_SESSION_ID")
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        return (process, output)
    }

    /// Runs one `latch` command the way the app does: manifest on standard
    /// input, Latch's nesting marker removed.
    private func run(_ executable: URL, _ arguments: [String], input: Data?, environment extra: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "LATCH_SESSION_ID")
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "latch", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "latch \(arguments.joined(separator: " ")): \(errorText)"])
        }
        return data
    }
}
