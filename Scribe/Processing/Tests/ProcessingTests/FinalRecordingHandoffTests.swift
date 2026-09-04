import Foundation
import ScribeAppCore
import Testing
@testable import Processing

/// The gate exists to refuse. These cover the one case that may pass and every
/// reason a session must not reach transcription, because a wrong refusal costs
/// a transcript while a wrong acceptance silently transcribes the wrong audio.
@Suite("Final recording handoff") struct FinalRecordingHandoffTests {
    @Test func verifiedFinalMixProducesARequestCarryingTheSessionIDAsProvenance() throws {
        let session = try handoffSession(finalContents: "verified-final-mix")
        let request = try FinalRecordingHandoff(checksumOfFile: fakeChecksum)
            .request(forSessionAt: session.directory)

        #expect(request.sourceURL.lastPathComponent == "final.flac")
        #expect(request.provenance == TranscriptionProvenance(
            producerID: FinalRecordingHandoff.producerID,
            sessionID: session.sessionID
        ))
        #expect(request.languageMode == .automatic)
        #expect(request.speakerMatching == .enabled)
    }

    @Test func failedCleanupIsSurfacedRatherThanHandingOffARawTrack() throws {
        let session = try handoffSession(
            processing: ProcessingMetadata(
                state: .failed,
                errors: [
                    ManifestError(code: "timeline.gap", message: "an earlier stage complained"),
                    ManifestError(code: "mixdown.delayUncertain", message: "the echo delay could not be trusted"),
                ]
            ),
            // A raw system track is present under the final track's name, which is
            // exactly the substitution the handoff must never make.
            finalContents: "raw-system-track"
        )

        #expect(throws: FinalRecordingHandoffRefusal.cleanupFailed("the echo delay could not be trusted")) {
            try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
        }
    }

    @Test func processingStillRunningIsATransientRefusal() throws {
        let session = try handoffSession(processing: ProcessingMetadata(state: .running), finalContents: "partial")
        do {
            _ = try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
            Issue.record("A session mid-processing must not be handed off")
        } catch let refusal as FinalRecordingHandoffRefusal {
            #expect(refusal == .processingIncomplete(.running))
            // Transient refusals are silent: the job simply is not ready yet.
            #expect(refusal.isTransient)
        }
    }

    @Test func aFinalFileThatDoesNotMatchItsVerifiedChecksumIsRefused() throws {
        let session = try handoffSession(finalContents: "replaced-after-verification", checksum: "not-the-file-on-disk")
        do {
            _ = try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
            Issue.record("A final file that fails verification must not be handed off")
        } catch let refusal as FinalRecordingHandoffRefusal {
            #expect(refusal == .checksumMismatch(
                expected: "not-the-file-on-disk",
                actual: fakeChecksum(session.directory.appendingPathComponent("final.flac"))
            ))
            #expect(!refusal.isTransient)
        }
    }

    @Test func aMissingFinalFileIsRefusedEvenWhenTheManifestClaimsCompletion() throws {
        let session = try handoffSession(finalContents: nil)
        #expect(throws: FinalRecordingHandoffRefusal.finalFileMissing("final.flac")) {
            try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
        }
    }

    @Test func completionWithoutADescribedFinalTrackIsRefused() throws {
        let session = try handoffSession(tracks: RecorderTrackCollection(), finalContents: "orphan")
        #expect(throws: FinalRecordingHandoffRefusal.finalTrackNotDescribed) {
            try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
        }
    }

    @Test func anUnrecognizedSchemaVersionIsRefusedBeforeAnyFieldIsTrusted() throws {
        let session = try handoffSession(schemaVersion: 99, finalContents: "future-format")
        #expect(throws: FinalRecordingHandoffRefusal.unsupportedSchemaVersion(99)) {
            try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: session.directory)
        }
    }

    @Test func aSessionWithoutAManifestIsRefused() throws {
        let root = try handoffTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("not-a-session", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            _ = try FinalRecordingHandoff(checksumOfFile: fakeChecksum).request(forSessionAt: directory)
            Issue.record("A folder without a manifest must not be handed off")
        } catch let refusal as FinalRecordingHandoffRefusal {
            guard case .manifestUnreadable = refusal else {
                Issue.record("Expected a manifest-unreadable refusal, got \(refusal)")
                return
            }
        }
    }
}

// MARK: - Fixture

/// A stand-in hash: the real one is `FLACEncoder.sha256`, which is also what
/// wrote the manifest's value. Substituting it here keeps these tests about the
/// gate's decisions rather than about hashing.
private func fakeChecksum(_ url: URL) -> String {
    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    return "checksum(\(contents))"
}

private struct HandoffSession {
    let directory: URL
    let sessionID: UUID
}

private func handoffSession(
    schemaVersion: Int = RecorderSessionManifest.currentSchemaVersion,
    processing: ProcessingMetadata = ProcessingMetadata(state: .complete),
    tracks: RecorderTrackCollection? = nil,
    finalContents: String?,
    checksum: String? = nil
) throws -> HandoffSession {
    let root = try handoffTemporaryRoot()
    let directory = root.appendingPathComponent("2026-09-04 10-00-00", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let finalURL = directory.appendingPathComponent("final.flac")
    if let finalContents {
        try finalContents.write(to: finalURL, atomically: true, encoding: .utf8)
    }

    let sessionID = UUID()
    let resolvedTracks = tracks ?? RecorderTrackCollection(
        finalTrack: RecorderTrackManifest(
            sourceFormat: AudioSourceFormat(sampleRate: 48_000, channelCount: 2, formatDescription: "flac"),
            firstMediaTimestampSeconds: 0,
            frameCount: 48_000,
            fileName: "final.flac",
            checksum: checksum ?? fakeChecksum(finalURL)
        )
    )
    let manifest = RecorderSessionManifest(
        schemaVersion: schemaVersion,
        sessionID: sessionID,
        appBuild: "tests",
        macOSVersion: "tests",
        startedAt: Date(timeIntervalSince1970: 0),
        completionStatus: .complete,
        capture: CaptureMetadata(
            state: .complete,
            scope: CaptureScope(applicationBundleIdentifiers: ["com.example.meeting"], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "mic", name: "Microphone")
        ),
        tracks: resolvedTracks,
        processing: processing
    )
    try AtomicReplaceFileWriter().write(manifest, to: directory.appendingPathComponent("metadata.json"))
    return HandoffSession(directory: directory, sessionID: sessionID)
}

private func handoffTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScribeHandoffTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
