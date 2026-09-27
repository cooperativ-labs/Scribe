import Foundation
import ScribeMCPCore

// A thin process boundary for the Node relay integration test. Production runs
// this same RelayClient inside Scribe.app, with no child process.
guard CommandLine.arguments.count == 4 else { exit(2) }
let client = RelayClient(credentials: RelayCredentialsStore(file: URL(filePath: CommandLine.arguments[3])),
                         transcriptDirectory: URL(filePath: CommandLine.arguments[2]))
let emit: @Sendable (String) -> Void = { text in
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
do {
    try await client.link(origin: CommandLine.arguments[1])
    emit("linked")
    let running = Task {
        do { try await client.run { message in emit(message) } }
        catch { emit("run-error: \(error.localizedDescription)") }
    }
    let commands = AsyncStream<String> { continuation in
        DispatchQueue.global().async {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }
    }
    for await command in commands {
        do {
            switch command {
            case "code": emit("code: \(try await client.linkCode())")
            case "grants": emit("grants: \(try await client.grants())")
            case "revoke": try await client.revoke(); emit("revoked")
            case "unlink": running.cancel(); try await client.unlink(); emit("unlinked")
            default: emit("unknown")
            }
        } catch { emit("error: \(error.localizedDescription)") }
    }
    running.cancel()
} catch {
    emit("error: \(error.localizedDescription)")
    exit(1)
}
