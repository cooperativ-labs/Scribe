import AVFoundation
import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// A prober driven entirely by test expectations, so the import policy is
/// exercised without an ffprobe binary or real encoded media.
private struct StubProber: MediaProbing {
    /// Content prefixes that decide the outcome, keyed by the byte marker a
    /// fixture file starts with. Files are plain text so a test can state its
    /// intent in the fixture itself.
    let outcomes: [String: Result<MediaProbeResult, MediaProbeError>]
    let fallback: Result<MediaProbeResult, MediaProbeError>

    init(
        outcomes: [String: Result<MediaProbeResult, MediaProbeError>] = [:],
        fallback: Result<MediaProbeResult, MediaProbeError> = .success(.stubMono)
    ) {
        self.outcomes = outcomes
        self.fallback = fallback
    }

    func probe(_ sourceURL: URL) throws -> MediaProbeResult {
        switch outcomes[sourceURL.lastPathComponent] ?? fallback {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
}

private extension MediaProbeResult {
    static let stubMono = MediaProbeResult(
        container: .flac,
        audioStreams: [AudioStreamProbe(index: 0, codec: "flac", channels: 1, sampleRate: 48_000, duration: 12)],
        duration: 12
    )
    static let stubMultitrack = MediaProbeResult(
        container: .m4a,
        audioStreams: [
            AudioStreamProbe(index: 0, codec: "aac", channels: 2, sampleRate: 48_000, duration: 12),
            AudioStreamProbe(index: 1, codec: "aac", channels: 1, sampleRate: 48_000, duration: 12),
        ],
        duration: 12
    )
}

final class FolderImportServiceTests: XCTestCase {
    private var root: URL!
    private let configuration = ImportConfiguration(modelProfileID: "parakeet-v3")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Folder Import \u{1F4C1} \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Scanning and skip reasons

    func testMixedFolderReportsFailuresPerFileWithoutStoppingValidFiles() throws {
        try write("good one.flac", in: root)
        try write("broken.m4a", in: root)
        try write("locked.m4a", in: root)
        try write("weird.xyz", in: root)
        try write("good two.flac", in: root)

        let prober = StubProber(outcomes: [
            "broken.m4a": .failure(.corrupt(details: "moov atom not found")),
            "locked.m4a": .failure(.encrypted(details: "drm protected")),
            "weird.xyz": .failure(.unsupported(details: "detected container \"matroska\"")),
        ])
        let result = try FolderImportService(prober: prober).scan(root, options: options())

        XCTAssertEqual(result.files.map(\.relativePath), ["broken.m4a", "good one.flac", "good two.flac", "locked.m4a", "weird.xyz"])
        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["good one.flac", "good two.flac"])
        XCTAssertEqual(result.failedFiles.map { $0.failure?.code }, [
            "import.file.corrupt", "import.file.encrypted", "import.file.unsupported",
        ])
        // A failed file still explains itself, and still has no fingerprint.
        let broken = try XCTUnwrap(result.files.first { $0.relativePath == "broken.m4a" })
        XCTAssertEqual(broken.deselectionReason, broken.failure?.message)
        XCTAssertNil(broken.fingerprint)
        XCTAssertNil(broken.probe)
        // The valid files were fully inspected regardless of their neighbors.
        XCTAssertTrue(result.preselectedFiles.allSatisfy { $0.fingerprint != nil && $0.probe != nil })
    }

    func testUnreadableFileIsReportedWithoutStoppingTheScan() throws {
        try write("readable.flac", in: root)
        let unreadable = try write("unreadable.flac", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options())

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["readable.flac"])
        XCTAssertEqual(result.files.first { $0.relativePath == "unreadable.flac" }?.failure?.code, "import.file.unreadable")
    }

    func testExcludesHiddenTemporaryTranscriptStoreAndCaptureEntries() throws {
        try write("keep.flac", in: root)
        try write(".hidden.flac", in: root)
        try write(".DS_Store", in: root)
        try write("recording.flac.part", in: root)
        try write("half written.tmp", in: root)
        try write("~$notes.flac", in: root)
        try write("editor backup.flac~", in: root)

        let store = root.appendingPathComponent("Meeting Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try write("source.flac", in: store)

        let session = try makeRecorderSession(named: "session", processing: .complete)
        let capture = session.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try write("segment-0.caf", in: capture)

        let result = try FolderImportService(prober: StubProber()).scan(
            root,
            options: options(includeSubfolders: true, transcriptStore: store)
        )

        XCTAssertEqual(result.files.map(\.relativePath), ["keep.flac", "session/final.flac", "session/microphone.flac", "session/system.flac"])
        let reasons = Dictionary(uniqueKeysWithValues: result.excluded.map { ($0.relativePath, $0.reason) })
        XCTAssertEqual(reasons[".hidden.flac"], .hidden)
        XCTAssertEqual(reasons[".DS_Store"], .hidden)
        XCTAssertEqual(reasons["recording.flac.part"], .temporary)
        XCTAssertEqual(reasons["half written.tmp"], .temporary)
        XCTAssertEqual(reasons["~$notes.flac"], .temporary)
        XCTAssertEqual(reasons["editor backup.flac~"], .temporary)
        XCTAssertEqual(reasons["Meeting Transcripts"], .transcriptStore)
        XCTAssertEqual(reasons["session/capture"], .recorderCaptureDirectory)
    }

    func testSubfoldersAreScannedOnlyWhenRequestedAndAreReportedWhenSkipped() throws {
        try write("top.flac", in: root)
        let nested = root.appendingPathComponent("interviews/day two", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("nested.flac", in: nested)

        let service = FolderImportService(prober: StubProber())

        let shallow = try service.scan(root, options: options())
        XCTAssertEqual(shallow.files.map(\.relativePath), ["top.flac"])
        XCTAssertEqual(shallow.excluded.map(\.reason), [.subfolder])

        let deep = try service.scan(root, options: options(includeSubfolders: true))
        XCTAssertEqual(deep.files.map(\.relativePath), ["interviews/day two/nested.flac", "top.flac"])
        XCTAssertTrue(deep.excluded.isEmpty)
    }

    func testDoesNotFollowSymlinksOutOfTheSelectedTreeButFollowsInternalOnes() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Outside \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapee = try write("elsewhere.flac", in: outside)

        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let target = try write("real.flac", in: inner)

        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.flac"), withDestinationURL: escapee)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape folder"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside.flac"), withDestinationURL: target)

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options(includeSubfolders: true))

        XCTAssertEqual(result.files.map(\.relativePath), ["inner/real.flac", "inside.flac"])
        let escapes = result.excluded.filter { if case .symlinkOutsideSelectedTree = $0.reason { return true } else { return false } }
        XCTAssertEqual(escapes.map(\.relativePath).sorted(), ["escape folder", "escape.flac"])
    }

    func testSortsNaturallyByRelativePathRatherThanLexically() throws {
        for name in ["track10.flac", "track2.flac", "track1.flac", "Track20.flac"] { try write(name, in: root) }
        let nested = root.appendingPathComponent("b folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("track3.flac", in: nested)
        try write("a file.flac", in: root)

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options(includeSubfolders: true))

        XCTAssertEqual(result.files.map(\.relativePath), [
            "a file.flac", "b folder/track3.flac", "track1.flac", "track2.flac", "track10.flac", "Track20.flac",
        ])
    }

    func testIdenticalFileNamesInDifferentFoldersStayDistinctRows() throws {
        let january = root.appendingPathComponent("january", isDirectory: true)
        let february = root.appendingPathComponent("february", isDirectory: true)
        for directory in [january, february] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write("standup.flac", in: january, contents: "january audio")
        try write("standup.flac", in: february, contents: "february audio")

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options(includeSubfolders: true))

        XCTAssertEqual(result.files.map(\.relativePath), ["february/standup.flac", "january/standup.flac"])
        XCTAssertEqual(Set(result.files.map(\.id)).count, 2)
        let fingerprints = result.files.compactMap(\.fingerprint)
        XCTAssertEqual(fingerprints.count, 2)
        XCTAssertNotEqual(fingerprints[0].contentHash, fingerprints[1].contentHash)
        XCTAssertNotEqual(fingerprints[0].sourceID, fingerprints[1].sourceID)
    }

    func testMultitrackContainerIsFlaggedForExplicitStreamSelection() throws {
        try write("interview.m4a", in: root)
        let prober = StubProber(outcomes: ["interview.m4a": .success(.stubMultitrack)])

        let file = try XCTUnwrap(try FolderImportService(prober: prober).scan(root, options: options()).files.first)

        XCTAssertTrue(file.requiresStreamSelection)
        XCTAssertEqual(file.probe?.audioStreams.map(\.index), [0, 1])
    }

    func testFingerprintingCanBeDeferredWithoutAffectingTheListing() throws {
        try write("one.flac", in: root)
        var deferred = options()
        deferred.fingerprintsDuringScan = false

        let result = try FolderImportService(prober: StubProber()).scan(root, options: deferred)

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["one.flac"])
        XCTAssertNil(result.files[0].fingerprint)
    }

    // MARK: - Recorder sessions in every processing state

    func testRecognizedCompleteSessionPreselectsOnlyTheVerifiedFinalMix() throws {
        let session = try makeRecorderSession(named: "meeting", processing: .complete)

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["final.flac"])
        let roles = Dictionary(uniqueKeysWithValues: result.files.map { ($0.relativePath, $0.recorderTrackRole) })
        XCTAssertEqual(roles["final.flac"], .finalMix)
        XCTAssertEqual(roles["system.flac"], .system)
        XCTAssertEqual(roles["microphone.flac"], .microphone)
        for name in ["system.flac", "microphone.flac"] {
            let track = try XCTUnwrap(result.files.first { $0.relativePath == name })
            XCTAssertFalse(track.isPreselected)
            // Unselected, but still importable and still explained.
            XCTAssertTrue(track.isImportable)
            let reason = try XCTUnwrap(track.deselectionReason)
            XCTAssertTrue(reason.contains("final mix is selected instead"), reason)
        }
        XCTAssertEqual(result.recorderSessions.count, 1)
        XCTAssertTrue(result.recorderSessions[0].isEligible)
    }

    func testEveryNonCompleteProcessingStateLeavesTheFinalMixUnselectedWithAReason() throws {
        let expectations: [(ProcessingState, String)] = [
            (.pending, "Audio cleanup is pending"),
            (.running, "Audio cleanup is running"),
            (.failed, "Audio cleanup failed"),
        ]

        for (state, expected) in expectations {
            let session = try makeRecorderSession(named: "session-\(state.rawValue)", processing: state)
            let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

            XCTAssertTrue(result.preselectedFiles.isEmpty, "\(state.rawValue) preselected \(result.preselectedFiles.map(\.relativePath))")
            let finalMix = try XCTUnwrap(result.files.first { $0.relativePath == "final.flac" })
            let reason = try XCTUnwrap(finalMix.deselectionReason)
            XCTAssertTrue(reason.hasPrefix(expected), "\(state.rawValue): \(reason)")
            // The raw tracks explain both facts: what they are and why the session was refused.
            let microphone = try XCTUnwrap(result.files.first { $0.relativePath == "microphone.flac" })
            XCTAssertTrue(microphone.deselectionReason?.contains("microphone track of a recording") == true)
            XCTAssertTrue(microphone.deselectionReason?.contains(expected) == true)
            XCTAssertFalse(result.recorderSessions[0].isEligible)
        }
    }

    func testFailedProcessingReportsTheMixdownReasonItRecorded() throws {
        let session = try makeRecorderSession(named: "failed", processing: .failed, errors: [
            ManifestError(code: "capture.deviceLost", message: "the microphone disappeared"),
            ManifestError(code: "mixdown.alignmentFailed", message: "the tracks could not be aligned"),
        ])

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        let reason = try XCTUnwrap(result.files.first { $0.relativePath == "final.flac" }?.deselectionReason)
        XCTAssertTrue(reason.contains("the tracks could not be aligned"), reason)
    }

    func testChecksumMismatchRefusesTheFinalMix() throws {
        let session = try makeRecorderSession(named: "tampered", processing: .complete)
        // Rewrite final.flac after the manifest recorded its checksum.
        try "different audio".write(to: session.appendingPathComponent("final.flac"), atomically: true, encoding: .utf8)

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        XCTAssertTrue(result.preselectedFiles.isEmpty)
        let reason = try XCTUnwrap(result.files.first { $0.relativePath == "final.flac" }?.deselectionReason)
        XCTAssertTrue(reason.contains("does not match the one the recorder verified"), reason)
        XCTAssertEqual(result.recorderSessions[0].rejection?.code, "import.session.checksumMismatch")
    }

    func testUnsupportedSchemaVersionRefusesTheSession() throws {
        let session = try makeRecorderSession(named: "future", processing: .complete, schemaVersion: 99)

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        XCTAssertTrue(result.preselectedFiles.isEmpty)
        XCTAssertEqual(result.recorderSessions[0].rejection, .unsupportedSchemaVersion(99))
    }

    func testUndecodableManifestWithholdsPreselectionFromConventionalTracks() throws {
        let session = try makeRecorderSession(named: "corrupt", processing: .complete)
        try Data("{ not json".utf8).write(to: session.appendingPathComponent("metadata.json"))

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        XCTAssertTrue(result.preselectedFiles.isEmpty)
        guard case .manifestUnreadable = try XCTUnwrap(result.recorderSessions[0].rejection) else {
            return XCTFail("Expected an unreadable-manifest rejection")
        }
    }

    func testAFolderWithoutAManifestIsOrdinaryMediaRegardlessOfFileNames() throws {
        // A filename alone must not imply a recorder session.
        for name in ["final.flac", "system.flac", "microphone.flac"] { try write(name, in: root) }

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options())

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["final.flac", "microphone.flac", "system.flac"])
        XCTAssertTrue(result.recorderSessions.isEmpty)
        XCTAssertTrue(result.files.allSatisfy { $0.recorderTrackRole == nil })
    }

    func testUnrelatedMediaInsideASessionFolderStaysOrdinary() throws {
        let session = try makeRecorderSession(named: "meeting", processing: .complete)
        try write("voice memo.flac", in: session)

        let result = try FolderImportService(prober: StubProber()).scan(session, options: options())

        let memo = try XCTUnwrap(result.files.first { $0.relativePath == "voice memo.flac" })
        XCTAssertNil(memo.recorderTrackRole)
        XCTAssertTrue(memo.isPreselected)
        XCTAssertEqual(result.preselectedFiles.map(\.relativePath).sorted(), ["final.flac", "voice memo.flac"])
    }

    func testScanningAParentFolderRecognizesEachSessionIndependently() throws {
        let complete = try makeRecorderSession(named: "a complete", processing: .complete)
        _ = try makeRecorderSession(named: "b running", processing: .running)
        try write("loose.flac", in: root)

        let result = try FolderImportService(prober: StubProber()).scan(root, options: options(includeSubfolders: true))

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["a complete/final.flac", "loose.flac"])
        XCTAssertEqual(result.recorderSessions.count, 2)
        XCTAssertEqual(result.recorderSessions.filter(\.isEligible).map(\.directoryURL.lastPathComponent), [complete.lastPathComponent])
    }

    // MARK: - Helpers

    private func options(includeSubfolders: Bool = false, transcriptStore: URL? = nil) -> FolderImportOptions {
        FolderImportOptions(
            configuration: configuration,
            includeSubfolders: includeSubfolders,
            transcriptStoreDirectory: transcriptStore
        )
    }

    @discardableResult
    private func write(_ name: String, in directory: URL, contents: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try (contents ?? "audio bytes for \(name)").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Builds a recorder session folder whose manifest records the real
    /// checksums of the files written beside it.
    @discardableResult
    private func makeRecorderSession(
        named name: String,
        processing state: ProcessingState,
        schemaVersion: Int = RecorderSessionManifest.currentSchemaVersion,
        errors: [ManifestError] = []
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func track(_ fileName: String) throws -> RecorderTrackManifest {
            let url = try write(fileName, in: directory)
            return RecorderTrackManifest(
                sourceFormat: AudioSourceFormat(sampleRate: 48_000, channelCount: 1, formatDescription: "flac"),
                firstMediaTimestampSeconds: 0,
                frameCount: 480_000,
                fileName: fileName,
                checksum: try FileContentHash.sha256(ofFileAt: url).digest
            )
        }

        let manifest = RecorderSessionManifest(
            schemaVersion: schemaVersion,
            sessionID: UUID(),
            appBuild: "test",
            macOSVersion: "15.0",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            durationSeconds: 600,
            completionStatus: state == .failed ? .failed : .complete,
            capture: CaptureMetadata(
                state: .complete,
                scope: CaptureScope(applicationBundleIdentifiers: ["com.example.calls"], processIdentifiers: []),
                microphone: AudioDeviceIdentity(uniqueID: "mic-1", name: "Built-in")
            ),
            tracks: RecorderTrackCollection(
                system: try track("system.flac"),
                microphone: try track("microphone.flac"),
                finalTrack: try track("final.flac")
            ),
            processing: ProcessingMetadata(state: state, errors: errors)
        )
        try AtomicReplaceFileWriter().write(
            try RecorderSessionManifestCodec.encode(manifest),
            to: directory.appendingPathComponent("metadata.json")
        )
        return directory
    }
}

/// Exercises the same policy against real encoded media and the real prober, so
/// the stub above cannot drift from what ffprobe actually reports.
final class FolderImportIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Folder Import Integration \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testScansRealMediaAndSeparatesUnsupportedFilesFromValidOnes() throws {
        let ffprobe = try findExecutable(named: "ffprobe")
        let ffmpeg = try findFixtureEncoder()
        let source = try writePCM(name: "source.wav")
        try transcode(source, to: root.appendingPathComponent("take 2.flac"), arguments: ["-c:a", "flac", "-f", "flac"], using: ffmpeg)
        try transcode(source, to: root.appendingPathComponent("take 10.m4a"), arguments: ["-c:a", "aac", "-f", "ipod"], using: ffmpeg)
        try Data([0x00, 0xF1, 0xB5, 0x7E]).write(to: root.appendingPathComponent("not audio.flac"))
        try "notes".write(to: root.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let result = try FolderImportService(prober: MediaProber(ffprobeURL: ffprobe)).scan(
            root,
            options: FolderImportOptions(configuration: ImportConfiguration(modelProfileID: "parakeet-v3"))
        )

        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["source.wav", "take 2.flac", "take 10.m4a"])
        XCTAssertEqual(result.failedFiles.map(\.relativePath), ["not audio.flac", "readme.txt"])
        XCTAssertEqual(result.files.first { $0.relativePath == "take 2.flac" }?.probe?.container, .flac)
        // Every fingerprint is distinct because every encoding is distinct.
        XCTAssertEqual(Set(result.preselectedFiles.compactMap { $0.fingerprint?.contentHash }).count, 3)
        for failed in result.failedFiles { XCTAssertNotNil(failed.deselectionReason) }
    }

    private func writePCM(name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames: AVAudioFrameCount = 12_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.03) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func transcode(_ source: URL, to destination: URL, arguments: [String], using ffmpeg: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-y", "-v", "error", "-i", source.path] + arguments + [destination.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ffmpeg failed for \(destination.lastPathComponent)")
    }

    private func findExecutable(named name: String) throws -> URL {
        let environmentName = "SCRIBE_\(name.uppercased())"
        if let path = ProcessInfo.processInfo.environment[environmentName], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        for path in ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Install the pinned FFmpeg toolchain with Scripts/build-ffmpeg.sh, then set \(environmentName) for this integration test.")
    }

    private func findFixtureEncoder() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["SCRIBE_FIXTURE_FFMPEG"], FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        for path in ["/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"] where FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        throw XCTSkip("Set SCRIBE_FIXTURE_FFMPEG to an FFmpeg build with the encoders needed to create fixtures.")
    }
}
