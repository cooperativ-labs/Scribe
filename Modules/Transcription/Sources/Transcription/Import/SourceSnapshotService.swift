import CryptoKit
import Foundation
import ScribeAppCore

/// A stable local copy of an import source, living in the transcript store.
///
/// Originals are never modified or relocated. The snapshot exists so that
/// processing and playback keep working when the selected folder is read-only,
/// is unmounted, or is edited after the import.
public struct SourceSnapshot: Equatable, Sendable {
    public let originalURL: URL
    public let snapshotURL: URL
    public let meetingDirectoryURL: URL
    public let sourceID: String
    public let fingerprint: ImportFingerprint
    /// True when an identical snapshot was already present and was reused.
    public let reusedExistingSnapshot: Bool
}

/// Whether this exact content, and this exact configuration, were seen before.
public enum ImportRepeatStatus: Equatable, Sendable {
    case new
    /// The same audio was imported before, but never with this configuration.
    /// A rerun is warranted; a previous transcript may still be worth offering.
    case sameContentNewConfiguration(meetingDirectoryURL: URL)
    /// The same audio has already been run with this exact configuration.
    /// Offer the existing result or an explicit rerun.
    case alreadyImported(meetingDirectoryURL: URL)

    public var meetingDirectoryURL: URL? {
        switch self {
        case .new: nil
        case .sameContentNewConfiguration(let url), .alreadyImported(let url): url
        }
    }
}

/// The importer-owned sidecar recorded beside `source.<ext>`.
///
/// It stays separate from the coordinator's `job.json` so that repeat-import
/// detection does not depend on the job format, and so a deleted run directory
/// does not erase the knowledge that this content was imported.
public struct SourceSnapshotRecord: Codable, Equatable, Sendable {
    public static let fileName = "import.json"
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sourceID: String
    public var contentHash: String
    public var byteCount: Int64
    public var snapshotFileName: String
    /// Every original location this content has been imported from. Identical
    /// file names in different folders stay distinct entries here.
    public var originalPaths: [String]
    /// Configuration fingerprints already imported for this content.
    public var configurationHashes: [String]
    public var createdAt: Date
    public var updatedAt: Date
}

public enum SourceSnapshotError: Error, Equatable, Sendable {
    case sourceUnreadable(String)
    /// The source changed, or was still being written, while it was copied.
    /// The caller returns the file to a waiting or error state and retries later.
    case sourceChangedDuringCopy(detail: String)
    case destinationUnwritable(String)

    public var code: String {
        switch self {
        case .sourceUnreadable: "import.snapshot.sourceUnreadable"
        case .sourceChangedDuringCopy: "import.snapshot.sourceChangedDuringCopy"
        case .destinationUnwritable: "import.snapshot.destinationUnwritable"
        }
    }
}

extension SourceSnapshotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let reason): "The source file could not be read: \(reason)"
        case .sourceChangedDuringCopy(let detail): "The source file changed while it was being copied: \(detail)"
        case .destinationUnwritable(let reason): "The transcript store could not be written: \(reason)"
        }
    }
}

/// Creates and identifies the stable local copies described in plan section 8.
///
/// Layout: `<store>/meeting--<source-id>/source.<original-extension>`, with the
/// importer's `import.json` sidecar beside it. Runs live under `runs/`, which
/// this service never touches.
public struct SourceSnapshotService: Sendable {
    public static let meetingDirectoryPrefix = "meeting--"

    public let storeDirectory: URL
    // FileManager's documented contract permits concurrent use of an instance's
    // file operations; the reference is held unsafely rather than making the
    // whole service a class just to satisfy the checker.
    nonisolated(unsafe) private let fileManager: FileManager
    private let writer: AtomicReplaceFileWriter

    public init(storeDirectory: URL, fileManager: FileManager = .default, writer: AtomicReplaceFileWriter = AtomicReplaceFileWriter()) {
        self.storeDirectory = storeDirectory
        self.fileManager = fileManager
        self.writer = writer
    }

    public func meetingDirectoryURL(forSourceID sourceID: String) -> URL {
        storeDirectory.appendingPathComponent(Self.meetingDirectoryPrefix + sourceID, isDirectory: true)
    }

    /// Reports whether this content and configuration were imported before.
    ///
    /// Detection is content-addressed, so a file renamed or copied to another
    /// folder is still recognized, and two different files that happen to share
    /// a name never collide.
    public func repeatStatus(for fingerprint: ImportFingerprint) -> ImportRepeatStatus {
        let directory = meetingDirectoryURL(forSourceID: fingerprint.sourceID)
        guard let record = readRecord(in: directory), record.contentHash == fingerprint.contentHash else { return .new }
        return record.configurationHashes.contains(fingerprint.configurationHash)
            ? .alreadyImported(meetingDirectoryURL: directory)
            : .sameContentNewConfiguration(meetingDirectoryURL: directory)
    }

    public func readRecord(in meetingDirectoryURL: URL) -> SourceSnapshotRecord? {
        let url = meetingDirectoryURL.appendingPathComponent(SourceSnapshotRecord.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SourceSnapshotRecord.self, from: data)
    }

    /// Copies `originalURL` into the store and verifies it did not change.
    ///
    /// The copy is hashed as it is written, in one pass, and compared against
    /// the fingerprint taken during the scan; the original's size and
    /// modification date are re-read afterwards. Any disagreement means the file
    /// was still being written or was edited mid-import, and the snapshot is
    /// discarded rather than committed.
    @discardableResult
    public func createSnapshot(
        of originalURL: URL,
        fingerprint: ImportFingerprint,
        fileExtension: String? = nil,
        now: Date = Date()
    ) throws -> SourceSnapshot {
        let before = try attributes(of: originalURL)
        let meetingDirectory = meetingDirectoryURL(forSourceID: fingerprint.sourceID)
        do { try fileManager.createDirectory(at: meetingDirectory, withIntermediateDirectories: true) }
        catch { throw SourceSnapshotError.destinationUnwritable(error.localizedDescription) }

        let resolvedExtension = (fileExtension ?? originalURL.pathExtension).lowercased()
        let snapshotName = resolvedExtension.isEmpty ? "source" : "source.\(resolvedExtension)"
        let destination = meetingDirectory.appendingPathComponent(snapshotName)

        // An identical snapshot already in place is reused rather than rewritten:
        // a repeat import must not disturb a source a previous run is playing back.
        if let existing = try? FileContentHash.sha256(ofFileAt: destination), existing.digest == fingerprint.contentHash {
            try recordImport(of: originalURL, fingerprint: fingerprint, snapshotFileName: snapshotName, in: meetingDirectory, now: now)
            return SourceSnapshot(
                originalURL: originalURL,
                snapshotURL: destination,
                meetingDirectoryURL: meetingDirectory,
                sourceID: fingerprint.sourceID,
                fingerprint: fingerprint,
                reusedExistingSnapshot: true
            )
        }

        let temporary = meetingDirectory.appendingPathComponent(".\(snapshotName).\(UUID().uuidString).partial")
        let copied: (digest: String, byteCount: Int64)
        do {
            copied = try copyHashing(from: originalURL, to: temporary)
        } catch let error as SourceSnapshotError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw SourceSnapshotError.sourceUnreadable(error.localizedDescription)
        }

        func discard(_ error: SourceSnapshotError) -> SourceSnapshotError {
            try? fileManager.removeItem(at: temporary)
            return error
        }

        guard copied.digest == fingerprint.contentHash, copied.byteCount == fingerprint.byteCount else {
            throw discard(.sourceChangedDuringCopy(
                detail: "the copied bytes no longer match the file that was scanned (\(fingerprint.byteCount) bytes expected, \(copied.byteCount) copied)"
            ))
        }
        let after: FileSnapshotAttributes
        do { after = try attributes(of: originalURL) } catch { throw discard(.sourceChangedDuringCopy(detail: "the source became unreadable during the copy")) }
        guard after == before else {
            throw discard(.sourceChangedDuringCopy(detail: "the source's size or modification date changed during the copy"))
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw discard(.destinationUnwritable(error.localizedDescription))
        }

        try recordImport(of: originalURL, fingerprint: fingerprint, snapshotFileName: snapshotName, in: meetingDirectory, now: now)
        return SourceSnapshot(
            originalURL: originalURL,
            snapshotURL: destination,
            meetingDirectoryURL: meetingDirectory,
            sourceID: fingerprint.sourceID,
            fingerprint: fingerprint,
            reusedExistingSnapshot: false
        )
    }

    private func recordImport(
        of originalURL: URL,
        fingerprint: ImportFingerprint,
        snapshotFileName: String,
        in meetingDirectory: URL,
        now: Date
    ) throws {
        let path = originalURL.standardizedFileURL.path
        var record = readRecord(in: meetingDirectory) ?? SourceSnapshotRecord(
            schemaVersion: SourceSnapshotRecord.currentSchemaVersion,
            sourceID: fingerprint.sourceID,
            contentHash: fingerprint.contentHash,
            byteCount: fingerprint.byteCount,
            snapshotFileName: snapshotFileName,
            originalPaths: [],
            configurationHashes: [],
            createdAt: now,
            updatedAt: now
        )
        record.snapshotFileName = snapshotFileName
        record.byteCount = fingerprint.byteCount
        if !record.originalPaths.contains(path) { record.originalPaths.append(path) }
        if !record.configurationHashes.contains(fingerprint.configurationHash) {
            record.configurationHashes.append(fingerprint.configurationHash)
        }
        record.updatedAt = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try writer.write(try encoder.encode(record), to: meetingDirectory.appendingPathComponent(SourceSnapshotRecord.fileName))
        } catch {
            throw SourceSnapshotError.destinationUnwritable(error.localizedDescription)
        }
    }

    /// Copies and hashes in a single streaming pass so the verification never
    /// re-reads a source that may be changing underneath it.
    private func copyHashing(from source: URL, to destination: URL) throws -> (digest: String, byteCount: Int64) {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw SourceSnapshotError.destinationUnwritable("could not create \(destination.lastPathComponent)")
        }
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch { throw SourceSnapshotError.sourceUnreadable(error.localizedDescription) }
        defer { try? input.close() }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: destination) }
        catch { throw SourceSnapshotError.destinationUnwritable(error.localizedDescription) }
        defer { try? output.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let chunk: Data?
            do { chunk = try input.read(upToCount: 1 << 20) }
            catch { throw SourceSnapshotError.sourceUnreadable(error.localizedDescription) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            do { try output.write(contentsOf: chunk) }
            catch { throw SourceSnapshotError.destinationUnwritable(error.localizedDescription) }
            byteCount += Int64(chunk.count)
        }
        try? output.synchronize()
        return (hasher.finalize().scribeHexString, byteCount)
    }

    private func attributes(of url: URL) throws -> FileSnapshotAttributes {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return FileSnapshotAttributes(
                byteCount: Int64(values.fileSize ?? -1),
                modifiedAt: values.contentModificationDate
            )
        } catch {
            throw SourceSnapshotError.sourceUnreadable(error.localizedDescription)
        }
    }
}

private struct FileSnapshotAttributes: Equatable {
    let byteCount: Int64
    let modifiedAt: Date?
}
