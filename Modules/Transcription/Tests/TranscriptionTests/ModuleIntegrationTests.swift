import AVFoundation
import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

/// The milestone 5 gate: folder → transcript → review → three-format export.
///
/// Every link is the shipping object. The real `FolderImportService` scans real
/// encoded media, the real `TranscriptionCoordinator` snapshots and queues it,
/// the real `TranscriptAssemblyStageRunner` reconciles timings and builds turns,
/// the real `TranscriptStore` reads the run back off disk, and the real
/// `TranscriptViewModel` exports through the real exporters. Only the four
/// stages that load Core ML models are scripted, and they are scripted by
/// writing exactly the artifacts the helper writes.
final class ModuleIntegrationTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Module Integration \(UUID().uuidString)", isDirectory: true)
        storeURL = root.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAChosenFolderReachesAThreeFormatExportThroughReview() async throws {
        let ffprobe = try findExecutable(named: "ffprobe")
        let folder = root.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meeting = try writeAudio(named: "team sync.wav", in: folder, seconds: 6)
        // A file the prober refuses. One bad file in a folder must not stop the
        // rest of the folder from being transcribed.
        try Data([0x00, 0xF1, 0xB5, 0x7E]).write(to: folder.appending(path: "broken.flac"))

        let result = try FolderImportService(prober: MediaProber(ffprobeURL: ffprobe)).scan(
            folder,
            options: FolderImportOptions(
                configuration: ImportConfiguration(modelProfileID: "parakeet-v3"),
                transcriptStoreDirectory: storeURL
            )
        )
        XCTAssertEqual(result.preselectedFiles.map(\.relativePath), ["team sync.wav"])
        XCTAssertEqual(result.failedFiles.map(\.relativePath), ["broken.flac"])

        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        for file in result.preselectedFiles {
            _ = try await coordinator.enqueue(TranscriptionRequest(sourceURL: file.url, modelProfileID: "parakeet-v3"))
        }
        await coordinator.runPending()

        // Review reads the store, not the coordinator: a completed job is
        // forgotten in memory and must still be reviewable after a relaunch.
        let store = TranscriptStore(storeDirectoryURL: storeURL)
        let runs = store.latestRunPerSource()
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.job.state, .complete)
        XCTAssertEqual(run.transcript?.source.filename, "team sync.wav")
        // The snapshot the transcript points at is a copy the module owns; the
        // original the user chose is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.job.sourceSnapshotURL.path))
        XCTAssertNotEqual(run.job.sourceSnapshotURL.standardizedFileURL, meeting.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.path))

        let transcript = try XCTUnwrap(run.transcript)
        XCTAssertEqual(transcript.segments.map(\.text), ["Hello there.", "Good to see you.", "Shall we start?"])
        XCTAssertEqual(transcript.segments.map(\.speakerLabel), ["Speaker 1", "Speaker 2", "Speaker 1"])
        // A → B → A stays in chronological order through the whole pipeline.
        XCTAssertEqual(transcript.segments.map(\.startMs).sorted(), transcript.segments.map(\.startMs))
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(transcript))

        let playback = RecordingPlayback()
        let model = await TranscriptViewModel(
            files: store.latestRunPerSource().map(TranscriptReviewFile.init),
            playback: playback,
            revisionStore: TranscriptStoreRevisionWriter(store: store)
        )
        let exports = root.appending(path: "Exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        await MainActor.run { model.export(Set(TranscriptExportFormat.allCases), to: exports) }

        let outcomes = await model.exportOutcomes
        XCTAssertEqual(outcomes.count, 3)
        for outcome in outcomes {
            XCTAssertTrue(outcome.succeeded, "\(outcome.format) failed: \(outcome.errorMessage ?? "")")
            let url = try XCTUnwrap(outcome.destinationURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let text = try String(contentsOf: exports.appending(path: "team sync.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Speaker 1: Hello there."), "TXT export was:\n\(text)")
        let srt = try String(contentsOf: exports.appending(path: "team sync.srt"), encoding: .utf8)
        XCTAssertTrue(srt.contains("-->"), "SRT export was:\n\(srt)")
        let json = try CanonicalTranscriptCodec.decode(Data(contentsOf: exports.appending(path: "team sync.json")))
        XCTAssertEqual(json.segments.count, transcript.segments.count)
    }

    /// Selecting a segment seeks the retained snapshot, which is what makes a
    /// speaker label checkable rather than merely displayed.
    func testSelectingASegmentSeeksTheStoredSnapshot() async throws {
        let source = try writeAudio(named: "call.wav", in: root, seconds: 4)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        _ = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "parakeet-v3"))
        await coordinator.runPending()

        let store = TranscriptStore(storeDirectoryURL: storeURL)
        let playback = RecordingPlayback()
        let model = await TranscriptViewModel(
            files: store.latestRunPerSource().map(TranscriptReviewFile.init),
            playback: playback
        )
        let segment = try await MainActor.run { try XCTUnwrap(model.chronologicalSegments.dropFirst().first) }
        await MainActor.run { model.select(segment: segment) }

        let loaded = await playback.loadedURL
        let seeks = await playback.seeks
        XCTAssertEqual(loaded?.standardizedFileURL, store.latestRunPerSource().first?.job.sourceSnapshotURL.standardizedFileURL)
        XCTAssertEqual(seeks, [segment.startMs])
    }

    /// Deleting from review removes the whole meeting from the store: the
    /// snapshot and its runs, so nothing older resurfaces in the list.
    func testDeletingAReviewedFileRemovesItsMeetingFromTheStore() async throws {
        let source = try writeAudio(named: "call.wav", in: root, seconds: 4)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner())
        )
        _ = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "parakeet-v3"))
        await coordinator.runPending()

        let store = TranscriptStore(storeDirectoryURL: storeURL)
        let run = try XCTUnwrap(store.latestRunPerSource().first)
        let meeting = run.runDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.path))

        let model = await TranscriptViewModel(
            files: store.latestRunPerSource().map(TranscriptReviewFile.init),
            playback: RecordingPlayback(),
            fileDeleter: TranscriptStoreFileDeleter(store: store)
        )
        await MainActor.run { model.delete(fileID: run.job.runID.uuidString) }

        let remaining = await MainActor.run { model.files }
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.path))
        XCTAssertTrue(store.runs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the original the user chose is untouched")
    }

    /// A run that fails mid-pipeline keeps its earlier checkpoints and is
    /// presented as failed rather than as an empty transcript.
    func testAFailedAssemblyIsReportedWithoutInventingATranscript() async throws {
        let source = try writeAudio(named: "call.wav", in: root, seconds: 4)
        let coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeURL),
            // Diarization commits nothing, so assembly cannot read its artifact.
            stageRunner: ScriptedWorkerStageRunner(hostStageRunner: TranscriptAssemblyStageRunner(), writesDiarization: false)
        )
        _ = try await coordinator.enqueue(TranscriptionRequest(sourceURL: source, modelProfileID: "parakeet-v3"))
        await coordinator.runPending()

        let store = TranscriptStore(storeDirectoryURL: storeURL)
        let run = try XCTUnwrap(store.latestRunPerSource().first)
        XCTAssertEqual(run.job.state, .failed)
        XCTAssertNil(run.transcript)
        XCTAssertNotNil(run.job.checkpoints[.transcribing], "the completed stages before the failure must survive it")
        XCTAssertEqual(TranscriptReviewFile(run).jobState, .failed(message: "This transcription failed."))
        XCTAssertNotNil(TranscriptReviewFile(run).processingError)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeAudio(named name: String, in directory: URL, seconds: Double) throws -> URL {
        let url = directory.appending(path: name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.02) * 0.4 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func findExecutable(named name: String) throws -> URL {
        let environmentName = "SCRIBE_\(name.uppercased())"
        if let path = ProcessInfo.processInfo.environment[environmentName], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        for path in ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("Install the pinned FFmpeg toolchain with Scripts/build-ffmpeg.sh, then set \(environmentName) for this integration test.")
    }
}

/// Writes the artifacts the bundled helper writes, without loading a model.
///
/// The point of the seam is that the coordinator and the host stages only ever
/// see committed files. Producing those files directly exercises the same
/// contract the real helper satisfies, which `WorkerIntegrationTests` covers
/// separately against the real binary.
struct ScriptedWorkerStageRunner: TranscriptionStageRunning {
    let hostStageRunner: any TranscriptionStageRunning
    var writesDiarization = true

    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        switch stage {
        case .preparing:
            return TranscriptionStageOutput(artifactURL: try write([
                "preparedAudioPath": .string(job.runDirectoryURL.appending(path: "prepared.wav").path),
                "sourceDurationSeconds": .number(6),
                "sampleRate": .number(16_000),
                "channels": .number(1),
            ], named: TranscriptRunArtifact.prepare, in: job))
        case .transcribing:
            let transcript = WorkerASRTranscript(
                text: "Hello there. Good to see you. Shall we start?",
                tokens: Self.tokens,
                sourceDurationSeconds: 6
            )
            let url = job.runDirectoryURL.appending(path: TranscriptRunArtifact.workerTranscript)
            try AtomicReplaceFileWriter().write(try WorkerASRTranscriptCodec.encode(transcript), to: url)
            return TranscriptionStageOutput(artifactURL: url)
        case .diarizing:
            guard writesDiarization else { return TranscriptionStageOutput() }
            return TranscriptionStageOutput(artifactURL: try write([
                "sourceDurationSeconds": .number(6),
                "usedDiskBackedAudio": .boolean(false),
                "intervals": .array([
                    interval(speaker: "speaker_1", start: 0, end: 1.6),
                    interval(speaker: "speaker_2", start: 1.7, end: 3.4),
                    interval(speaker: "speaker_1", start: 3.5, end: 5.4),
                ]),
            ], named: TranscriptRunArtifact.diarization, in: job))
        case .matchingSpeakers:
            return TranscriptionStageOutput(artifactURL: try write(
                ["embeddings": .array([])], named: TranscriptRunArtifact.embeddings, in: job
            ))
        default:
            return try await hostStageRunner.run(stage: stage, job: job)
        }
    }

    /// Three turns of two speakers, A → B → A, with word timings inside them.
    private static let tokens: [WorkerTimedToken] = {
        let script: [(String, Double, Double)] = [
            ("Hello", 0.10, 0.55), (" there.", 0.60, 1.20),
            (" Good", 1.80, 2.10), (" to", 2.15, 2.35), (" see", 2.40, 2.70), (" you.", 2.75, 3.20),
            (" Shall", 3.60, 3.95), (" we", 4.00, 4.20), (" start?", 4.25, 5.00),
        ]
        return script.enumerated().map { index, token in
            WorkerTimedToken(text: token.0, tokenID: index + 1, startSeconds: token.1, endSeconds: token.2)
        }
    }()

    private func interval(speaker: String, start: Double, end: Double) -> TranscriptJSONValue {
        .object([
            "speakerID": .string(speaker),
            "startSeconds": .number(start),
            "endSeconds": .number(end),
            "qualityScore": .number(0.9),
            "overlapsAnotherSpeaker": .boolean(false),
        ])
    }

    private func write(_ value: [String: TranscriptJSONValue], named name: String, in job: TranscriptionJob) throws -> URL {
        let url = job.runDirectoryURL.appending(path: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicReplaceFileWriter().write(try encoder.encode(value), to: url)
        return url
    }
}

/// Records what review asked playback to do.
@MainActor
final class RecordingPlayback: TranscriptPlaybackSeeking {
    private(set) var loadedURL: URL?
    private(set) var seeks: [Int] = []

    func load(sourceSnapshotURL: URL) { loadedURL = sourceSnapshotURL }
    func seek(toMilliseconds milliseconds: Int) { seeks.append(milliseconds) }
}
