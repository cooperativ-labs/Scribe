import XCTest
import ScribeAppCore

final class ScribeAppTests: XCTestCase {
    func testHostPackageProvidesTheApplicationName() {
        XCTAssertEqual(ScribeAppCore.displayName, "Scribe")
    }
}
