import Foundation

enum InspectCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let journalPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
            fputs("capture-harness inspect: pass the path to a timeline.jsonl\n", stderr)
            return 64
        }
        let reportJSON = arguments.contains("--json")
        do {
            let report = try TimestampInspector.inspect(journalURL: URL(fileURLWithPath: journalPath))
            if reportJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try encoder.encode(report), encoding: .utf8)!)
            } else {
                print(render(report))
            }
            return 0
        } catch {
            fputs("capture-harness: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func render(_ report: InspectionReport) -> String {
        var lines: [String] = []
        lines.append("Journal: \(report.journal)")
        lines.append("Buffers: \(report.parsedBuffers); ignored lines: \(report.ignoredLines)")
        lines.append("Clock relationship: \(report.clockRelationship)")
        for track in report.tracks.keys.sorted() {
            guard let item = report.tracks[track] else { continue }
            lines.append("")
            lines.append(".\(track): initial PTS \(String(format: "%.9f", item.initialTimestampSeconds)) s; \(item.bufferCount) buffers; \(item.deliveredFrames) frames")
            if let drift = item.driftSeconds, let ppm = item.driftPPM {
                lines.append("  timestamp/sample span drift: \(String(format: "%+.6f", drift)) s (\(String(format: "%+.3f", ppm)) ppm)")
            } else {
                lines.append("  timestamp/sample span drift: unavailable (\(item.missingSampleRateBuffers) buffers lack a sample rate)")
            }
            lines.append("  gaps: \(item.gaps.count); overlaps: \(item.overlaps.count); format changes: \(item.formatChanges.count)")
            item.formats.forEach { lines.append("  format: \($0)") }
        }
        report.warnings.forEach { lines.append("Warning: \($0)") }
        lines.append("")
        lines.append("Timeline rule: \(report.timelineRule)")
        return lines.joined(separator: "\n")
    }
}
