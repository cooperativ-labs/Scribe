import Foundation
import ScribeAppCore
import Transcription

/// A stage runner that costs what a transcription stage costs.
///
/// The coexistence gate is about resource contention, so a stage runner that
/// returns immediately would prove nothing. This one occupies CPU on several
/// threads and holds a working set for the length of each stage, then commits
/// exactly the artifacts the real helper commits so the real host stages —
/// timing reconciliation and turn assembly — run on top of it unchanged.
///
/// It is deliberately not the real helper: the release gate must be able to run
/// on a machine with no Core ML models installed, and a synthetic load whose
/// size is printed in the report is more honest than a model run whose cost
/// varies with the recording it is given.
public struct TranscriptionLoad: TranscriptionStageRunning {
    /// Seconds of occupied CPU per worker stage.
    public let secondsPerStage: Double
    /// Threads kept busy for those seconds.
    public let threads: Int
    /// Megabytes held resident while a stage runs.
    public let workingSetMegabytes: Int
    public let hostStageRunner: any TranscriptionStageRunning
    /// Records when a stage was running, so the report can say whether any
    /// transcription work overlapped capture.
    public let observer: LoadObserver

    public init(
        secondsPerStage: Double,
        threads: Int,
        workingSetMegabytes: Int,
        hostStageRunner: any TranscriptionStageRunning,
        observer: LoadObserver
    ) {
        self.secondsPerStage = secondsPerStage
        self.threads = threads
        self.workingSetMegabytes = workingSetMegabytes
        self.hostStageRunner = hostStageRunner
        self.observer = observer
    }

    public func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        guard let name = Self.artifactNames[stage] else {
            return try await hostStageRunner.run(stage: stage, job: job)
        }
        await observer.stageStarted(stage)
        defer { Task { await observer.stageFinished(stage) } }
        await burn()
        return TranscriptionStageOutput(artifactURL: try commitArtifact(named: name, stage: stage, in: job))
    }

    private static let artifactNames: [TranscriptionJobState: String] = [
        .preparing: TranscriptRunArtifact.prepare,
        .transcribing: TranscriptRunArtifact.workerTranscript,
        .diarizing: TranscriptRunArtifact.diarization,
        .matchingSpeakers: TranscriptRunArtifact.embeddings,
    ]

    private func burn() async {
        let deadline = Date().addingTimeInterval(secondsPerStage)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, threads) {
                group.addTask {
                    // A resident allocation per thread, touched as it spins, so
                    // the load competes for memory bandwidth and not only for
                    // scheduler time.
                    var block = [Double](repeating: 1.000_001, count: max(1, workingSetMegabytes) * 131_072 / max(1, threads))
                    var accumulator = 0.0
                    while Date() < deadline {
                        for index in stride(from: 0, to: block.count, by: 64) {
                            block[index] = block[index] * 1.000_000_1 + 0.000_1
                            accumulator += block[index]
                        }
                    }
                    if accumulator == .infinity { print("") }
                }
            }
        }
    }

    private func commitArtifact(named name: String, stage: TranscriptionJobState, in job: TranscriptionJob) throws -> URL {
        let url = job.runDirectoryURL.appending(path: name)
        let data: Data
        switch stage {
        case .transcribing:
            let words = ["Coexistence", " load", " trans", "cript."]
            var tokens: [WorkerTimedToken] = []
            for (index, word) in words.enumerated() {
                let start = Double(index) * 0.4 + 0.1
                tokens.append(WorkerTimedToken(text: word, tokenID: index + 1, startSeconds: start, endSeconds: start + 0.25))
            }
            data = try WorkerASRTranscriptCodec.encode(WorkerASRTranscript(
                text: words.joined(),
                tokens: tokens,
                sourceDurationSeconds: 4
            ))
        case .preparing:
            let prepared: [String: Any] = [
                "preparedAudioPath": job.runDirectoryURL.appending(path: "prepared.wav").path,
                "sourceDurationSeconds": 4.0,
                "sampleRate": 16_000,
                "channels": 1,
            ]
            data = try encode(prepared)
        case .diarizing:
            let first: [String: Any] = [
                "speakerID": "speaker_1", "startSeconds": 0.0, "endSeconds": 2.0,
                "qualityScore": 0.9, "overlapsAnotherSpeaker": false,
            ]
            let second: [String: Any] = [
                "speakerID": "speaker_2", "startSeconds": 2.0, "endSeconds": 3.9,
                "qualityScore": 0.9, "overlapsAnotherSpeaker": false,
            ]
            let diarization: [String: Any] = [
                "sourceDurationSeconds": 4.0,
                "usedDiskBackedAudio": false,
                "intervals": [first, second],
            ]
            data = try encode(diarization)
        default:
            let embeddings: [String: Any] = ["embeddings": [] as [Any]]
            data = try encode(embeddings)
        }
        try AtomicReplaceFileWriter().write(data, to: url)
        return url
    }

    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }
}

/// Records the intervals in which transcription stages were running, so the
/// report can state whether any of them overlapped the recording.
public actor LoadObserver {
    public init() {}

    private(set) var stageStartTimes: [Date] = []
    private(set) var running = 0
    private(set) var busyIntervals: [(start: Date, end: Date)] = []
    private var currentStart: Date?

    public func stageStarted(_ stage: TranscriptionJobState) {
        stageStartTimes.append(Date())
        if running == 0 { currentStart = Date() }
        running += 1
    }

    public func stageFinished(_ stage: TranscriptionJobState) {
        running = max(0, running - 1)
        if running == 0, let currentStart {
            busyIntervals.append((currentStart, Date()))
            self.currentStart = nil
        }
    }

    /// Seconds of transcription work that overlapped the capture window.
    public func secondsOverlapping(start: Date, end: Date) -> TimeInterval {
        var intervals = busyIntervals
        if let currentStart { intervals.append((currentStart, Date())) }
        return intervals.reduce(0) { total, interval in
            let overlap = min(interval.end, end).timeIntervalSince(max(interval.start, start))
            return total + max(0, overlap)
        }
    }

    public func stagesStarted(between start: Date, and end: Date) -> Int {
        stageStartTimes.count { $0 >= start && $0 <= end }
    }
}
