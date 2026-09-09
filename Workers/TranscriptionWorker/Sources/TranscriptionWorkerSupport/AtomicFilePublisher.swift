import Foundation

/// Publishes worker artifacts with a same-directory atomic move or replace.
/// The caller may stage bytes or a converted media file; publication semantics
/// stay identical for both paths.
enum AtomicFilePublisher {
    static func write(_ data: Data, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: staged)
            try publish(staged, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func publish(_ staged: URL, to destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
