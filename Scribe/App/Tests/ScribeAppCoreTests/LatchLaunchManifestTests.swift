import Foundation
import XCTest
@testable import ScribeAppCore

final class LatchLaunchManifestTests: XCTestCase {
    func testTheEncodedDocumentUsesLatchsOwnFieldNames() throws {
        let manifest = LatchLaunchManifest(
            launch: .init(
                argv: ["/Users/example/.local/bin/claude", "Summarize the call."],
                cwd: "/Users/example/Development/Scribe",
                env: ["SCRIBE_TRANSCRIPT_FILE": "/tmp/standup.txt"]
            ),
            display: .init(
                name: "scribe-standup",
                title: "Monday standup",
                commandLabel: "claude",
                source: .init(kind: "scribe", externalRunID: "transcript_42")
            )
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try manifest.encoded()) as? [String: Any])
        XCTAssertEqual(object["format_version"] as? Int, 1)

        let launch = try XCTUnwrap(object["launch"] as? [String: Any])
        XCTAssertEqual(launch["argv"] as? [String], ["/Users/example/.local/bin/claude", "Summarize the call."])
        XCTAssertEqual(launch["cwd"] as? String, "/Users/example/Development/Scribe")
        XCTAssertEqual(launch["inherit_env"] as? Bool, true)
        XCTAssertEqual(launch["term"] as? String, "xterm-256color")
        XCTAssertEqual((launch["env"] as? [String: String])?["SCRIBE_TRANSCRIPT_FILE"], "/tmp/standup.txt")
        let size = try XCTUnwrap(launch["size"] as? [String: Any])
        XCTAssertEqual(size["cols"] as? Int, 120)
        XCTAssertEqual(size["rows"] as? Int, 40)

        let display = try XCTUnwrap(object["display"] as? [String: Any])
        XCTAssertEqual(display["name"] as? String, "scribe-standup")
        XCTAssertEqual(display["title"] as? String, "Monday standup")
        XCTAssertEqual(display["command_label"] as? String, "claude")
        let source = try XCTUnwrap(display["source"] as? [String: Any])
        XCTAssertEqual(source["kind"] as? String, "scribe")
        XCTAssertEqual(source["external_run_id"] as? String, "transcript_42")
    }

    func testTheThreeThingsLatchWouldRejectAreRefusedBeforeItIsRun() {
        let display = LatchLaunchManifest.Display(name: nil, title: nil, commandLabel: nil, source: .init(kind: "scribe"))

        XCTAssertThrowsError(
            try LatchLaunchManifest(launch: .init(argv: [], cwd: "/tmp"), display: display).encoded()
        ) { XCTAssertEqual($0 as? LatchLaunchManifestError, .missingProgram) }

        XCTAssertThrowsError(
            try LatchLaunchManifest(launch: .init(argv: ["claude"], cwd: "relative/path"), display: display).encoded()
        ) { XCTAssertEqual($0 as? LatchLaunchManifestError, .relativeWorkingDirectory("relative/path")) }

        XCTAssertThrowsError(
            try LatchLaunchManifest(
                launch: .init(argv: ["claude"], cwd: "/tmp", size: .init(cols: 0, rows: 40)),
                display: display
            ).encoded()
        ) { XCTAssertEqual($0 as? LatchLaunchManifestError, .emptyTerminalSize) }
    }

    func testTheCreateReportIsReadEvenWhenLatchAddsFieldsToIt() throws {
        let json = Data("""
        {"protocolVersion":2,"session":{"id":"ses_1a07","name":"scribe-standup","state":"running","createdAt":"2026-08-30T12:00:00Z","extra":{"unknown":true}}}
        """.utf8)

        let report = try LatchCreateReport.decode(json)

        XCTAssertEqual(report.protocolVersion, 2)
        XCTAssertEqual(report.session.id, "ses_1a07")
        XCTAssertEqual(report.session.name, "scribe-standup")
        XCTAssertEqual(report.session.state, "running")
    }
}
