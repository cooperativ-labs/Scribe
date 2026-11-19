import Foundation
import XCTest

/// Decision 9: the prompt, MCP URL and send history never reach Scribe's logs
/// or diagnostics. Exports and the relay are checked against real files in
/// `MeetingNotesLifecycleTests` and the MCP tests; this guards the log sinks,
/// which no behavioural test can read back, by scanning every app source for
/// a logging or debug-capture call that names a handoff setting.
final class HandoffPrivacyTests: XCTestCase {
    func testNoLogOrDebugCaptureCallNamesTheHandoffSettings() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscriptionTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Transcription
            .deletingLastPathComponent() // Modules
            .deletingLastPathComponent()
        let roots = ["Modules/Transcription/Sources", "Scribe/App", "Scribe/UI/Sources", "Scribe/Platform/Sources", "Scribe/Capture/Sources"]
            .map { repository.appending(path: $0, directoryHint: .isDirectory) }
        let sink = try NSRegularExpression(pattern: #"(logger\.\w+\(|Logger\(|os_log\(|NSLog\(|\bprint\(|debugPrint\(|MessageDebugLog\.shared\.record\(|captureDebugMessage\()"#)
        let sensitive = try NSRegularExpression(pattern: #"(mcpURL|\.instruction\b|handoff\.prompt|settings\.prompt|request\.prompt|\.handoff\b|\bsnapshot\b|notesBlock|\.notes\b)"#)

        var scanned = 0
        var offenders: [String] = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/.build/") {
                scanned += 1
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    guard sink.firstMatch(in: line, range: range) != nil,
                          sensitive.firstMatch(in: line, range: range) != nil else { continue }
                    offenders.append("\(url.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan must actually find the app's sources")
        XCTAssertEqual(offenders, [], "a log or debug-capture call names private handoff data")
    }
}
