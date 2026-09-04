import Foundation
import Processing

/// Headless entry point for recovery and intentional reruns. It deliberately
/// delegates to the same transaction as the app queue, so it has identical
/// atomic publication and failure behavior.
public enum ScribeProcessSupport {
    @discardableResult
    public static func process(sessionDirectory: URL) throws -> MixdownResult {
        try SessionProcessor().run(sessionDirectory: sessionDirectory)
    }
}
