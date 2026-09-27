@testable import Assist
import XCTest

final class KeychainStoreTests: XCTestCase {
    /// Round-trips a generic-password item under a throwaway service, so the
    /// real `co.cooperativ.scribe.chatgpt` items are never touched.
    func testWriteReadOverwriteDelete() throws {
        let store = KeychainStore(service: "co.cooperativ.scribe.tests.\(UUID().uuidString)")
        do {
            try store.write(Data("one".utf8), for: "item")
        } catch let error as KeychainError {
            throw XCTSkip("The Keychain is not available to this test process: \(error.localizedDescription)")
        }
        defer { try? store.delete("item") }
        XCTAssertEqual(try store.read("item"), Data("one".utf8))
        XCTAssertTrue(try store.contains("item"))
        XCTAssertFalse(try store.contains("other"))
        try store.write(Data("two".utf8), for: "item")
        XCTAssertEqual(try store.read("item"), Data("two".utf8))
        try store.delete("item")
        XCTAssertNil(try store.read("item"))
        XCTAssertNoThrow(try store.delete("item"), "deleting a missing item is not an error")
    }

    func testServicesAreScribesOwn() {
        XCTAssertEqual(KeychainStore.chatGPTService, "co.cooperativ.scribe.chatgpt")
        XCTAssertNotEqual(KeychainStore.openAIService, KeychainStore.chatGPTService)
    }
}
