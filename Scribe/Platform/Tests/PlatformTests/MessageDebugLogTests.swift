import Platform
import XCTest

@MainActor
final class MessageDebugLogTests: XCTestCase {
    func testOptInPersistenceDisableAndClear() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = MessageDebugLog(defaults: fixture.defaults, fileURL: fixture.url)
        log.record("Should not be captured", source: "Test")
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))

        log.isEnabled = true
        log.record("A flashing warning", source: "Dictation", level: .warning)
        log.isEnabled = false
        let count = log.entries.count
        log.record("Disabled", source: "Test")
        XCTAssertEqual(log.entries.count, count)
        await log.flush()

        let reloaded = MessageDebugLog(defaults: fixture.defaults, fileURL: fixture.url)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.entries, log.entries)
        XCTAssertTrue(reloaded.exportText().contains("[warning] Dictation: A flashing warning"))
        reloaded.clear()
        await reloaded.flush()
        let cleared = MessageDebugLog(defaults: fixture.defaults, fileURL: fixture.url)
        XCTAssertTrue(cleared.entries.isEmpty)
    }

    func testBoundedHistoryPreservesOrderAndMilliseconds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = MessageDebugLog(defaults: fixture.defaults, fileURL: fixture.url, limit: 3,
                                  now: { Date(timeIntervalSince1970: 1_000.125) })
        log.isEnabled = true
        for index in 0..<10 { log.record("Message \(index)", source: "Test") }
        XCTAssertEqual(log.entries.map(\.message), ["Message 7", "Message 8", "Message 9"])
        XCTAssertTrue(log.exportText().contains("1970-01-01T00:16:40.125Z"))
        await log.flush()
        let saved = try JSONDecoder().decode([MessageDebugEntry].self, from: Data(contentsOf: fixture.url))
        XCTAssertEqual(saved, log.entries)
    }

    func testUnwritableHistoryKeepsMessagesInMemory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = MessageDebugLog(defaults: fixture.defaults, fileURL: fixture.url)
        XCTAssertNil(log.storageError)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        log.isEnabled = true
        log.record("Keep this warning", source: "Test")
        await log.flush()
        // The writer reports its result back to the main actor.
        await Task.yield()
        XCTAssertTrue(log.storageError?.hasPrefix("Could not save messages:") == true)
        XCTAssertTrue(log.exportText().contains("Keep this warning"))
    }

    private struct Fixture {
        let name = "MessageDebugLogTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let url: URL
        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            url = FileManager.default.temporaryDirectory.appending(path: name).appending(path: "messages.json")
        }
        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
}
