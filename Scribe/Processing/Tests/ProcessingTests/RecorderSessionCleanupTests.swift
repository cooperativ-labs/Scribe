import Foundation
import Testing
@testable import Processing

@Suite("Recorder session cleanup") struct RecorderSessionCleanupTests {
    @Test func removesOneMeetingDirectoryAndAllOfItsComponents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("2026-09-15 10-15-00", isDirectory: true)
        let capture = session.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data("final".utf8).write(to: session.appendingPathComponent("final.m4a"))
        try Data("component".utf8).write(to: capture.appendingPathComponent("microphone-0001.caf"))

        #expect(try RecorderSessionCleanup.removeSession(at: session, from: root))
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func missingSessionIsAnIdempotentNoOp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("already-removed", isDirectory: true)

        #expect(try !RecorderSessionCleanup.removeSession(at: missing, from: root))
    }

    @Test func refusesTheRootNestedAndOutsideDirectories() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let nested = root.appendingPathComponent("meeting/capture", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(throws: RecorderSessionCleanupError.self) {
            try RecorderSessionCleanup.removeSession(at: root, from: root)
        }
        #expect(throws: RecorderSessionCleanupError.self) {
            try RecorderSessionCleanup.removeSession(at: nested, from: root)
        }
        #expect(throws: RecorderSessionCleanupError.self) {
            try RecorderSessionCleanup.removeSession(at: outside, from: root)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderSessionCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
