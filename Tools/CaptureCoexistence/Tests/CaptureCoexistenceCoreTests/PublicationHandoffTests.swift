import AVFoundation
import CaptureCoexistenceCore
import Foundation
import Processing
import ScribeAppCore
import Testing
import Transcription

/// The second milestone 5 exit criterion: *a recorder session transcribes
/// automatically after publication when the toggle is on.*
///
/// This is the only place both halves of that sentence are real at once. The
/// recorder's `FinalRecordingHandoff` verifies a published session and its
/// `TranscriptionRequestOutbox` writes the request; the module's
/// `TranscriptionHandoffConsumer` drains it into a real
/// `TranscriptionCoordinator`, which produces a real canonical transcript. The
/// only step not exercised here is the capture that wrote `final.flac`, which
/// `Tools/CaptureIntegration` covers on real hardware.
///
/// It lives in this package because this is the one target that links the
/// recorder and the transcription module together, which is exactly the seam
/// under test.
@Suite struct PublicationHandoffTests {
    @Test func aPublishedRecordingBecomesATranscriptWithoutAnyoneAskingAgain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try publishSession(named: "2026-09-04 10-00-00", in: root)

        // Recorder side: verify the published session, then hand it over.
        let request = try FinalRecordingHandoff().request(forSessionAt: session)
        let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        try await outbox.submit(request)
        #expect(request.sourceURL.lastPathComponent == "final.flac")
        #expect(request.provenance?.producerID.isEmpty == false)

        // Transcription side: nothing here knows a recorder exists.
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)),
            stageRunner: TranscriptionLoad(
                secondsPerStage: 0,
                threads: 1,
                workingSetMegabytes: 1,
                hostStageRunner: TranscriptAssemblyStageRunner(),
                observer: LoadObserver()
            )
        )
        let outcome = try await TranscriptionHandoffConsumer(source: outbox).drain(into: coordinator)
        #expect(outcome.queued == [request.requestID])
        // Claimed, so a second launch does not transcribe the same meeting again.
        let remaining = try await outbox.pendingRequests()
        #expect(remaining.isEmpty)

        await coordinator.runPending()

        let store = TranscriptStore(storeDirectoryURL: root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory))
        let run = try #require(store.latestRunPerSource().first)
        #expect(run.job.state == .complete)
        #expect(run.job.request.provenance?.sessionID == request.provenance?.sessionID)
        let transcript = try #require(run.transcript)
        #expect(transcript.source.filename == "final.flac")
        #expect(!transcript.segments.isEmpty)

        // The transcript a person would then export, from the same revision.
        let exports = root.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let outcomes = FileTranscriptExportWriter().write(
            transcript,
            formats: Set(TranscriptExportFormat.allCases),
            to: exports
        )
        #expect(outcomes.count == 3)
        let failedExports = outcomes.filter { !$0.succeeded }
        #expect(failedExports.isEmpty)
    }

    /// A session whose cleanup failed publishes nothing. Handing over a raw
    /// track would read as a successful transcription of the meeting.
    @Test func aSessionWhoseCleanupFailedIsNeverHandedOver() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try publishSession(named: "2026-09-04 11-00-00", in: root, processing: .failed)

        do {
            _ = try FinalRecordingHandoff().request(forSessionAt: session)
            Issue.record("a session whose cleanup failed must not produce a transcription request")
        } catch let refusal as FinalRecordingHandoffRefusal {
            #expect(!refusal.isTransient)
        }
        let outbox = TranscriptionRequestOutbox.inRecordingsDirectory(root)
        let pending = try await outbox.pendingRequests()
        #expect(pending.isEmpty)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Scribe Publication \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A finished recorder session: real audio for every track, and a manifest
    /// whose checksums are the real checksums of what is beside it.
    private func publishSession(
        named name: String,
        in recordings: URL,
        processing state: ProcessingState = .complete
    ) throws -> URL {
        let directory = recordings.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func track(_ fileName: String) throws -> RecorderTrackManifest {
            let url = directory.appending(path: fileName)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let frames = AVAudioFrameCount(48_000 * 4)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.02) * 0.4 }
            // Real FLAC, because that is what the recorder publishes and what
            // the handoff checksums. The writer is released before the file is
            // hashed; hashing a file that is still open reads a partial one,
            // which is exactly the mismatch the handoff is there to catch.
            try {
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatFLAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                ])
                try file.write(from: buffer)
            }()
            return RecorderTrackManifest(
                sourceFormat: AudioSourceFormat(sampleRate: 48_000, channelCount: 1, formatDescription: "flac"),
                firstMediaTimestampSeconds: 0,
                frameCount: 192_000,
                fileName: fileName,
                checksum: try FileContentHash.sha256(ofFileAt: url).digest
            )
        }

        let manifest = RecorderSessionManifest(
            sessionID: UUID(),
            appBuild: "publication-tests",
            macOSVersion: "15.0",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_240),
            durationSeconds: 240,
            completionStatus: state == .complete ? .complete : .failed,
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
            processing: ProcessingMetadata(state: state)
        )
        try AtomicReplaceFileWriter().write(
            try RecorderSessionManifestCodec.encode(manifest),
            to: directory.appending(path: "metadata.json")
        )
        return directory
    }
}
