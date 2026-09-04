import Foundation

/// Appends one JSON object per line. Buffer records go to `timeline.jsonl`, which
/// `capture-harness inspect` reads; everything else goes to `events.jsonl` so the
/// timeline stays free of lines the inspector would count as ignored.
/// Appends are serialised: buffer records arrive on the writer queue while stream,
/// resource and interruption events arrive on the control, Core Audio and observer
/// queues, so the two file handles need a lock rather than a queue convention.
final class JournalWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let timeline: FileHandle
    private let events: FileHandle
    let timelineURL: URL
    let eventsURL: URL

    init(directory: URL) throws {
        timelineURL = directory.appendingPathComponent("timeline.jsonl")
        eventsURL = directory.appendingPathComponent("events.jsonl")
        for url in [timelineURL, eventsURL] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        timeline = try FileHandle(forWritingTo: timelineURL)
        events = try FileHandle(forWritingTo: eventsURL)
    }

    func append(_ record: [String: Any]) {
        write(record, to: timeline)
    }

    func appendEvent(_ record: [String: Any]) {
        var record = record
        record["wallClock"] = Timestamp.iso8601()
        write(record, to: events)
    }

    private func write(_ record: [String: Any], to handle: FileHandle) {
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        lock.withLock { try? handle.write(contentsOf: data) }
    }

    func synchronizeAndClose() {
        lock.lock()
        defer { lock.unlock() }
        try? timeline.synchronize()
        try? events.synchronize()
        try? timeline.close()
        try? events.close()
    }
}

enum Timestamp {
    static func iso8601(_ date: Date = Date()) -> String {
        date.ISO8601Format(.iso8601(timeZone: .current).time(includingFractionalSeconds: true))
    }

    /// Session directory name; matches the layout in IMPLEMENTATION_PLAN.md section 4.
    static func sessionStamp(_ date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0,
                      components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
    }
}
