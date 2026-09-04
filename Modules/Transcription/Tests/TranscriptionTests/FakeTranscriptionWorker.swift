import Foundation
@testable import Transcription

/// A scripted stand-in for the bundled helper.
///
/// It is a real executable driven over real pipes rather than an in-process
/// double, because most of what `WorkerClient` has to get right — newline
/// framing, an abrupt exit, a silent process, an oversize record — only exists
/// once there is a child process. The deterministic worker binary covers the
/// other direction in `WorkerIntegrationTests`.
struct FakeTranscriptionWorker {
    enum Step {
        /// Writes one record, substituting the run request's identifier.
        case emit(kind: String, payload: String)
        /// Writes a record whose version the host must reject.
        case emitRaw(String)
        /// Writes the contents of a file verbatim, for oversize records.
        case emitContentsOfFile(URL)
        case pauseSeconds(Double)
        /// Blocks until the host sends another record, such as a cancel.
        case awaitRecord
        /// Leaves abruptly, the way a crashing helper does.
        case crash
        case exitCode(Int32)
    }

    /// Overrides the handshake reply; the default one is well-formed.
    var handshakeRecord: String?
    var steps: [Step]

    init(handshakeRecord: String? = nil, steps: [Step]) {
        self.handshakeRecord = handshakeRecord
        self.steps = steps
    }

    /// Emits the four stage results of a healthy run, then `complete`.
    static func healthyRun(pauseSeconds: Double = 0) -> FakeTranscriptionWorker {
        var steps: [Step] = []
        for (stage, file) in [("prepare", "prepare.json"), ("transcribe", "transcript.json"), ("diarize", "diarization.json"), ("embed", "embeddings.json")] {
            steps.append(.emit(kind: "progress", payload: #"{"stage":"\#(stage)","state":"started"}"#))
            if pauseSeconds > 0 { steps.append(.pauseSeconds(pauseSeconds)) }
            steps.append(.emit(kind: "stage_result", payload: #"{"stage":"\#(stage)","status":"complete","resultPath":"\#(file)","sha256":"\#(String(repeating: "a", count: 64))"}"#))
        }
        steps.append(.emit(kind: "stage_result", payload: #"{"stage":"complete","status":"complete"}"#))
        return FakeTranscriptionWorker(steps: steps)
    }

    /// Writes the script and returns an installation pointing at it.
    func install(in directory: URL) throws -> WorkerInstallation {
        let url = directory.appending(path: "FakeTranscriptionWorker")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return WorkerInstallation(executableURL: url)
    }

    private func script() -> String {
        let handshake = handshakeRecord ?? #"{"version":1,"kind":"stage_result","requestID":"%s","payload":{"stage":"handshake","protocolVersion":1,"workerVersion":"fake-1.0","networking":"disabled","runtimeDownloads":false,"telemetry":false}}"#
        var lines = [
            "#!/bin/sh",
            "set -u",
            #"extract_id() { printf '%s' "$1" | sed -n 's/.*"requestID":"\([^"]*\)".*/\1/p'; }"#,
            "IFS= read -r line || exit 0",
            "RID=$(extract_id \"$line\")",
            "printf '\(handshake)\\n' \"$RID\"",
            "IFS= read -r line || exit 0",
            "RID=$(extract_id \"$line\")",
        ]
        for step in steps {
            switch step {
            case let .emit(kind, payload):
                lines.append("printf '{\"version\":1,\"kind\":\"\(kind)\",\"requestID\":\"%s\",\"payload\":\(payload)}\\n' \"$RID\"")
            case let .emitRaw(record):
                lines.append("printf '\(record)\\n' \"$RID\"")
            case let .emitContentsOfFile(url):
                lines.append("cat '\(url.path)'")
                lines.append("printf '\\n'")
            case let .pauseSeconds(seconds):
                lines.append("sleep \(seconds)")
            case .awaitRecord:
                lines.append("IFS= read -r cancel_line || exit 0")
            case .crash:
                lines.append("kill -9 $$")
            case let .exitCode(code):
                lines.append("exit \(code)")
            }
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n") + "\n"
    }
}
