import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

final class ImportFingerprintTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Fingerprint \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testIdenticalContentUnderDifferentNamesSharesOneSourceIdentity() throws {
        let first = try write("january/standup.flac", contents: "the same meeting")
        let second = try write("february/standup.flac", contents: "the same meeting")
        let different = try write("march/standup.flac", contents: "another meeting")
        let configuration = ImportConfiguration(modelProfileID: "parakeet-v3")

        let a = try ImportFingerprint(fileAt: first, configuration: configuration)
        let b = try ImportFingerprint(fileAt: second, configuration: configuration)
        let c = try ImportFingerprint(fileAt: different, configuration: configuration)

        XCTAssertEqual(a, b)
        XCTAssertEqual(a.sourceID, b.sourceID)
        XCTAssertNotEqual(a.sourceID, c.sourceID)
        XCTAssertEqual(a.byteCount, Int64("the same meeting".utf8.count))
    }

    func testConfigurationChangesTheRunIdentityButNotTheSourceIdentity() throws {
        let url = try write("audio.flac", contents: "meeting audio")
        let base = ImportConfiguration(modelProfileID: "parakeet-v3")

        var withKnownSpeakers = base
        withKnownSpeakers.speakerCount = .known(3)
        var withoutMatching = base
        withoutMatching.speakerMatching = .disabled
        var otherChannel = base
        otherChannel.channelSelection = .left
        var otherStream = base
        otherStream.audioStreamIndex = 1
        var otherRevision = base
        otherRevision.speakerLibraryRevision = "rev-2"

        let variants = try [base, withKnownSpeakers, withoutMatching, otherChannel, otherStream, otherRevision]
            .map { try ImportFingerprint(fileAt: url, configuration: $0) }

        XCTAssertEqual(Set(variants.map(\.configurationHash)).count, variants.count)
        XCTAssertEqual(Set(variants.map(\.sourceID)).count, 1, "A rerun is a new run inside the same meeting, not a new meeting")
        XCTAssertEqual(Set(variants.map(\.value)).count, variants.count)
    }

    func testConfigurationFingerprintIsStableAcrossEncodings() throws {
        let configuration = ImportConfiguration(
            modelProfileID: "parakeet-v3",
            expectedLanguage: "en",
            speakerCount: .known(2),
            speakerLibraryRevision: "rev-7"
        )
        // Field order in the struct must not leak into the hash.
        var reordered = ImportConfiguration(modelProfileID: "parakeet-v3")
        reordered.speakerLibraryRevision = "rev-7"
        reordered.speakerCount = .known(2)
        reordered.expectedLanguage = "en"

        XCTAssertEqual(configuration.fingerprint, reordered.fingerprint)
        XCTAssertEqual(configuration.fingerprint.count, 64)
    }

    @discardableResult
    private func write(_ relativePath: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class SourceSnapshotServiceTests: XCTestCase {
    private var root: URL!
    private var store: URL!
    private var service: SourceSnapshotService!
    private let configuration = ImportConfiguration(modelProfileID: "parakeet-v3")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Snapshot \(UUID().uuidString)", isDirectory: true)
        store = root.appendingPathComponent("Meeting Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = SourceSnapshotService(storeDirectory: store)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSnapshotCopiesIntoTheStoreLayoutAndLeavesTheOriginalUntouched() throws {
        let original = try write("interview.flac", contents: "meeting audio")
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: original.path)
        let fingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)

        let snapshot = try service.createSnapshot(of: original, fingerprint: fingerprint)

        XCTAssertEqual(snapshot.meetingDirectoryURL, store.appendingPathComponent("meeting--\(fingerprint.sourceID)"))
        XCTAssertEqual(snapshot.snapshotURL.lastPathComponent, "source.flac")
        XCTAssertEqual(try String(contentsOf: snapshot.snapshotURL, encoding: .utf8), "meeting audio")
        XCTAssertFalse(snapshot.reusedExistingSnapshot)
        // The original stays exactly where and as it was.
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(
            originalAttributes[.modificationDate] as? Date,
            try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date
        )
        // Nothing partial is left behind.
        let contents = try FileManager.default.contentsOfDirectory(atPath: snapshot.meetingDirectoryURL.path)
        XCTAssertEqual(contents.sorted(), ["import.json", "source.flac"])
    }

    func testExtensionlessSourceFallsBackToTheProbedContainer() throws {
        let original = try write("recording", contents: "meeting audio")
        let fingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)

        let snapshot = try service.createSnapshot(of: original, fingerprint: fingerprint, fileExtension: MediaContainer.flac.rawValue)

        XCTAssertEqual(snapshot.snapshotURL.lastPathComponent, "source.flac")
    }

    func testRepeatImportDetectionDistinguishesContentAndConfiguration() throws {
        let original = try write("interview.flac", contents: "meeting audio")
        let fingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)
        XCTAssertEqual(service.repeatStatus(for: fingerprint), .new)

        let snapshot = try service.createSnapshot(of: original, fingerprint: fingerprint)
        XCTAssertEqual(service.repeatStatus(for: fingerprint), .alreadyImported(meetingDirectoryURL: snapshot.meetingDirectoryURL))

        var rerun = configuration
        rerun.speakerCount = .known(4)
        let rerunFingerprint = try ImportFingerprint(fileAt: original, configuration: rerun)
        XCTAssertEqual(
            service.repeatStatus(for: rerunFingerprint),
            .sameContentNewConfiguration(meetingDirectoryURL: snapshot.meetingDirectoryURL)
        )

        // Recording the rerun adds a configuration without creating a second meeting.
        _ = try service.createSnapshot(of: original, fingerprint: rerunFingerprint)
        XCTAssertEqual(service.repeatStatus(for: rerunFingerprint), .alreadyImported(meetingDirectoryURL: snapshot.meetingDirectoryURL))
        let record = try XCTUnwrap(service.readRecord(in: snapshot.meetingDirectoryURL))
        XCTAssertEqual(record.configurationHashes.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path).count, 1)
    }

    func testSameContentFromASecondFolderIsOneMeetingWithBothOriginalsRecorded() throws {
        let first = try write("january/standup.flac", contents: "the same meeting")
        let second = try write("february/standup.flac", contents: "the same meeting")
        let fingerprint = try ImportFingerprint(fileAt: first, configuration: configuration)

        let a = try service.createSnapshot(of: first, fingerprint: fingerprint)
        let b = try service.createSnapshot(of: second, fingerprint: try ImportFingerprint(fileAt: second, configuration: configuration))

        XCTAssertEqual(a.meetingDirectoryURL, b.meetingDirectoryURL)
        XCTAssertTrue(b.reusedExistingSnapshot, "An identical snapshot is reused, not rewritten under a playing source")
        let record = try XCTUnwrap(service.readRecord(in: a.meetingDirectoryURL))
        XCTAssertEqual(record.originalPaths.count, 2)
        XCTAssertEqual(record.originalPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, ["standup.flac", "standup.flac"])
    }

    func testDifferentContentUnderTheSameNameNeverCollides() throws {
        let january = try write("january/standup.flac", contents: "january audio")
        let february = try write("february/standup.flac", contents: "february audio")

        let a = try service.createSnapshot(of: january, fingerprint: try ImportFingerprint(fileAt: january, configuration: configuration))
        let b = try service.createSnapshot(of: february, fingerprint: try ImportFingerprint(fileAt: february, configuration: configuration))

        XCTAssertNotEqual(a.meetingDirectoryURL, b.meetingDirectoryURL)
        XCTAssertEqual(try String(contentsOf: a.snapshotURL, encoding: .utf8), "january audio")
        XCTAssertEqual(try String(contentsOf: b.snapshotURL, encoding: .utf8), "february audio")
    }

    func testContentChangedAfterTheScanIsRefusedAndNothingIsCommitted() throws {
        let original = try write("growing.flac", contents: "first take")
        let staleFingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)
        // The user re-exported the file between the folder scan and the copy.
        try "a completely different second take".write(to: original, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.createSnapshot(of: original, fingerprint: staleFingerprint)) { error in
            guard case SourceSnapshotError.sourceChangedDuringCopy = error else {
                return XCTFail("Expected a change-detection refusal, got \(error)")
            }
        }
        let meeting = service.meetingDirectoryURL(forSourceID: staleFingerprint.sourceID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: meeting.path), [], "No partial snapshot may survive")
        XCTAssertEqual(service.repeatStatus(for: staleFingerprint), .new)
    }

    func testAFileStillBeingWrittenIsRefusedRatherThanSnapshottedShort() throws {
        // A growing file: the fingerprint describes only the bytes present so far.
        let original = try write("in progress.flac", contents: "chunk one")
        let partialFingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)
        let handle = try FileHandle(forWritingTo: original)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" chunk two".utf8))
        try handle.close()

        XCTAssertThrowsError(try service.createSnapshot(of: original, fingerprint: partialFingerprint)) { error in
            guard case SourceSnapshotError.sourceChangedDuringCopy(let detail) = error else {
                return XCTFail("Expected a change-detection refusal, got \(error)")
            }
            XCTAssertTrue(detail.contains("\(partialFingerprint.byteCount) bytes expected"), detail)
        }
    }

    func testUnreadableSourceIsAStructuredError() throws {
        let missing = root.appendingPathComponent("gone.flac")
        let fingerprint = ImportFingerprint(contentHash: String(repeating: "a", count: 64), byteCount: 10, configurationHash: configuration.fingerprint)

        XCTAssertThrowsError(try service.createSnapshot(of: missing, fingerprint: fingerprint)) { error in
            guard case SourceSnapshotError.sourceUnreadable = error else {
                return XCTFail("Expected a structured unreadable error, got \(error)")
            }
        }
    }

    func testARewrittenSnapshotReplacesAMismatchedOneAtomically() throws {
        let original = try write("interview.flac", contents: "meeting audio")
        let fingerprint = try ImportFingerprint(fileAt: original, configuration: configuration)
        let meeting = service.meetingDirectoryURL(forSourceID: fingerprint.sourceID)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        // A truncated leftover from an interrupted earlier import.
        try "meet".write(to: meeting.appendingPathComponent("source.flac"), atomically: true, encoding: .utf8)

        let snapshot = try service.createSnapshot(of: original, fingerprint: fingerprint)

        XCTAssertFalse(snapshot.reusedExistingSnapshot)
        XCTAssertEqual(try String(contentsOf: snapshot.snapshotURL, encoding: .utf8), "meeting audio")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: meeting.path).sorted(), ["import.json", "source.flac"])
    }

    func testSnapshotsFullEndToEndFromAScannedFolder() throws {
        let session = root.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "the final mix".write(to: session.appendingPathComponent("final.flac"), atomically: true, encoding: .utf8)
        try "the raw mic".write(to: session.appendingPathComponent("microphone.flac"), atomically: true, encoding: .utf8)

        let scan = try FolderImportService(prober: AlwaysFlacProber()).scan(
            session,
            options: FolderImportOptions(configuration: configuration, transcriptStoreDirectory: store)
        )
        let selected = try XCTUnwrap(scan.preselectedFiles.first)
        let snapshot = try service.createSnapshot(
            of: selected.url,
            fingerprint: try XCTUnwrap(selected.fingerprint),
            fileExtension: selected.probe?.container.rawValue
        )

        XCTAssertEqual(scan.preselectedFiles.count, 2, "Without a manifest these are ordinary files")
        XCTAssertEqual(try String(contentsOf: snapshot.snapshotURL, encoding: .utf8), "the final mix")
        XCTAssertEqual(service.repeatStatus(for: try XCTUnwrap(selected.fingerprint)).meetingDirectoryURL, snapshot.meetingDirectoryURL)
    }

    @discardableResult
    private func write(_ relativePath: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct AlwaysFlacProber: MediaProbing {
    func probe(_ sourceURL: URL) throws -> MediaProbeResult {
        MediaProbeResult(
            container: .flac,
            audioStreams: [AudioStreamProbe(index: 0, codec: "flac", channels: 1, sampleRate: 48_000, duration: 5)],
            duration: 5
        )
    }
}
