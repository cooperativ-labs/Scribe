import AVFoundation
import CaptureCoexistenceCore
import Foundation
import Processing
import ScribeAppCore
import Storage
import Transcription

/// The capture-coexistence gate for TRANSCRIPTION_IMPLEMENTATION_PLAN.md
/// section 11: no additional capture gaps in a controlled two-hour recording
/// with queued transcription, with recording priority enforced through the
/// scheduler contract.
///
/// It drives the shipping objects. `SessionStore` archives real CAF segments
/// through the real timeline journal at real capture cadence; `ProcessingQueue`
/// is the real `ProcessingScheduler`; `TranscriptionCoordinator` is the real
/// queue and asks that scheduler for permission exactly as it does in the app.
/// Only two things are stood in for: `SCStream`, which cannot be granted Screen
/// & System Audio Recording to a command-line tool, and the Core ML stages,
/// which are replaced by a CPU and memory load whose size this tool prints.
///
/// The recording is one continuous capture split into two halves. Nothing is
/// queued during the first half; the transcription jobs are queued at the
/// midpoint. Comparing the halves of a single recording controls for whatever
/// else the machine was doing far better than two separate runs would.
///
///     capture-coexistence run --seconds 7200
///     capture-coexistence run --seconds 300 --ignore-scheduler
///
/// `--ignore-scheduler` builds the coordinator with no scheduler, so
/// transcription runs during capture. It exists to show what the contract is
/// preventing: a gate that passes either way is measuring nothing.

struct Options {
    var seconds: Double = 7_200
    var jobs = 4
    var loadSecondsPerStage: Double = 20
    var loadThreads = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    var loadWorkingSetMegabytes = 512
    var ignoresScheduler = false
    /// Queues nothing at all. The control for the environment: if a baseline
    /// run's second half also degrades, the volume and the machine are what the
    /// gate is measuring, not the transcription queue.
    var isBaseline = false
    /// Unique per run. Two gates sharing one directory would overwrite each
    /// other's recording, and a run that cleared a fixed path would delete a
    /// concurrent run's audio out from under it.
    var outputDirectory = FileManager.default.temporaryDirectory
        .appending(path: "scribe-capture-coexistence-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    var reportURL: URL?
}

func usage() -> Never {
    print("""
    capture-coexistence -- the capture-coexistence gate for queued transcription.

    USAGE
      capture-coexistence run [--seconds 7200] [--jobs 4] [--output <dir>]
                              [--load-seconds 20] [--load-threads N] [--load-memory-mb 512]
                              [--ignore-scheduler] [--report <file.json>]

    One continuous recording. The first half runs with an empty transcription
    queue; the transcription jobs are queued at the midpoint. The gate passes
    when the second half has no more missed capture deadlines than the first,
    the whole recording is clean, no transcription stage overlapped the
    recording, and every queued job completed once the recording stopped.
    """)
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        func value() -> String {
            guard index < arguments.count else { usage() }
            defer { index += 1 }
            return arguments[index]
        }
        switch argument {
        case "--seconds": options.seconds = Double(value()) ?? options.seconds
        case "--jobs": options.jobs = Int(value()) ?? options.jobs
        case "--load-seconds": options.loadSecondsPerStage = Double(value()) ?? options.loadSecondsPerStage
        case "--load-threads": options.loadThreads = Int(value()) ?? options.loadThreads
        case "--load-memory-mb": options.loadWorkingSetMegabytes = Int(value()) ?? options.loadWorkingSetMegabytes
        case "--ignore-scheduler": options.ignoresScheduler = true
        case "--baseline": options.isBaseline = true
        case "--output": options.outputDirectory = URL(fileURLWithPath: value(), isDirectory: true)
        case "--report": options.reportURL = URL(fileURLWithPath: value())
        default: usage()
        }
    }
    return options
}

/// The conditions a run happened under.
///
/// A two-hour real-time measurement is only meaningful if the machine could
/// have met it. Recording free space and swap at both ends is what lets a
/// later reader tell a contract failure from an exhausted box — the first run
/// of this gate could not, and its failure was misattributed as a result.
struct Environment {
    var freeBytes: Int64
    var swapUsedBytes: Int64

    static func sample(at url: URL) -> Environment {
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swap = sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? Int64(usage.xsu_used) : 0
        return Environment(freeBytes: Int64(free), swapUsedBytes: swap)
    }

    var description: String {
        "\(freeBytes / 1_073_741_824)GB free, \(swapUsedBytes / 1_048_576)MB swap in use"
    }
}

/// A machine-wide lock, so two gates can never measure each other.
///
/// This gate measures a real-time property. A second one running beside it
/// competes for exactly the CPU and disk under test, so both results would be
/// wrong and neither would say so. The lock is advisory but checked: it holds
/// the owner's process id, and a stale one from a killed run is reclaimed.
enum GateLock {
    static let url = URL(fileURLWithPath: "/tmp/scribe-capture-coexistence.lock")

    static func acquire() -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            print("FAIL another capture-coexistence run is active (pid \(pid)). Wait for it, or stop it first.")
            return false
        }
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    static func release() {
        guard let owner = try? String(contentsOf: url, encoding: .utf8),
              Int32(owner.trimmingCharacters(in: .whitespacesAndNewlines)) == ProcessInfo.processInfo.processIdentifier
        else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Thrown to skip the pre-recording job in the baseline arm.
private struct BaselineArmQueuesNothing: Error {}

func run(_ options: Options) async -> Int32 {
    guard GateLock.acquire() else { return 1 }
    defer { GateLock.release() }
    let manager = FileManager.default
    let recordings = options.outputDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    let transcripts = options.outputDirectory.appending(path: "Meeting Transcripts", directoryHint: .isDirectory)
    let sources = options.outputDirectory.appending(path: "Sources", directoryHint: .isDirectory)
    // Refused rather than reused: a directory that already holds a run is very
    // likely another run in progress, and this tool writes gigabytes into it.
    guard !manager.fileExists(atPath: recordings.path) else {
        print("FAIL \(recordings.path) already exists. Pass --output for a directory this run owns.")
        return 1
    }
    for directory in [recordings, transcripts, sources] {
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let queue: ProcessingQueue
    let store: SessionStore
    do {
        queue = try ProcessingQueue(configuration: .inRecordingsDirectory(recordings))
        store = try SessionStore.create(configuration: SessionStoreConfiguration(
            recordingsDirectory: recordings,
            appBuild: "capture-coexistence",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            captureScope: CaptureScope(applicationBundleIdentifiers: ["io.cooperativ.scribe.coexistence"], processIdentifiers: []),
            microphone: AudioDeviceIdentity(uniqueID: "synthetic", name: "Synthetic")
        ))
    } catch {
        print("FAIL could not open the recorder's durable state: \(error.localizedDescription)")
        return 1
    }

    let observer = LoadObserver()
    let load = TranscriptionLoad(
        secondsPerStage: options.loadSecondsPerStage,
        threads: options.loadThreads,
        workingSetMegabytes: options.loadWorkingSetMegabytes,
        hostStageRunner: TranscriptAssemblyStageRunner(),
        observer: observer
    )
    let coordinator: TranscriptionCoordinator
    do {
        coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: transcripts),
            // The only difference between the gate and its control.
            scheduler: options.ignoresScheduler ? nil : queue,
            stageRunner: load
        )
    } catch {
        print("FAIL could not open the transcription queue: \(error.localizedDescription)")
        return 1
    }

    let sourceURLs: [URL]
    do {
        sourceURLs = try (0..<max(1, options.jobs)).map { try writeSource(named: "meeting \($0 + 1).wav", in: sources) }
    } catch {
        print("FAIL could not write the transcription sources: \(error.localizedDescription)")
        return 1
    }

    print("""
    Recording:     \(Int(options.seconds))s, buffers every \(String(format: "%.1f", CaptureWriter.bufferInterval * 1_000))ms
    Transcription: \(options.isBaseline ? "none (baseline arm: capture only)" : "\(options.jobs) job(s) queued at the midpoint")
    Stage load:    \(Int(options.loadSecondsPerStage))s on \(options.loadThreads) thread(s), \(options.loadWorkingSetMegabytes)MB resident
    Scheduler:     \(options.ignoresScheduler ? "IGNORED (control run)" : "ProcessingQueue, recording has priority")
    Store:         \(options.outputDirectory.path)
    """)

    // A job that is already running when the recording starts. The contract says
    // it suspends at its next persisted stage boundary rather than being killed.
    // The baseline arm queues nothing at all, this job included: its whole
    // purpose is to record with no transcription work anywhere in the run, so
    // that a degraded baseline indicts the machine and nothing else.
    var preexistingJobID: UUID?
    do {
        guard !options.isBaseline else { throw BaselineArmQueuesNothing() }
        let job = try await coordinator.enqueue(TranscriptionRequest(sourceURL: sourceURLs[0], modelProfileID: "coexistence"))
        preexistingJobID = job.id
        Task { await coordinator.runPending() }
        // Give it long enough to be genuinely inside a stage.
        try? await Task.sleep(for: .seconds(min(3, options.loadSecondsPerStage)))
    } catch is BaselineArmQueuesNothing {
        // Expected: the baseline arm has no pre-recording job.
    } catch {
        print("FAIL could not queue the pre-recording job: \(error.localizedDescription)")
        return 1
    }

    let environmentBefore = Environment.sample(at: options.outputDirectory)
    print("Environment:   \(environmentBefore.description)")
    let captureStarted = Date()
    await queue.setCaptureActive(true)

    let midpoint = options.seconds / 2
    let queuedAtMidpoint = Locked(false)
    let queueFailures = Locked<[String]>([])
    let writer = CaptureWriter(store: store)
    let report: CaptureWriter.Report
    do {
        report = try await writer.record(seconds: options.seconds, boundary: midpoint) { elapsed in
            guard !options.isBaseline else { return }
            guard elapsed >= midpoint, !queuedAtMidpoint.value else { return }
            queuedAtMidpoint.value = true
            // Queued off the capture path, the way the app queues a folder
            // import or a producer handoff. Snapshotting a source copies and
            // hashes a file; capture must never wait behind that.
            Task {
                for url in sourceURLs.dropFirst() {
                    do {
                        _ = try await coordinator.enqueue(TranscriptionRequest(sourceURL: url, modelProfileID: "coexistence"))
                    } catch {
                        queueFailures.mutate { $0.append(error.localizedDescription) }
                    }
                }
                // Offered to the queue during capture, exactly as the app offers
                // it. The scheduler is what decides nothing starts.
                await coordinator.runPending()
            }
        }
    } catch {
        print("FAIL the recording itself failed: \(error.localizedDescription)")
        return 1
    }
    let captureEnded = Date()
    let environmentAfter = Environment.sample(at: options.outputDirectory)

    await queue.setCaptureActive(false)
    print("Recording finished. Draining the transcription queue…")
    await coordinator.runPending()
    // A resume signal restarts the drain on the coordinator's own task, so wait
    // for the queue to empty rather than assuming one pass finished it.
    let drainDeadline = Date().addingTimeInterval(max(120, Double(options.jobs + 1) * options.loadSecondsPerStage * 6))
    while Date() < drainDeadline, await !coordinator.pendingJobs().isEmpty {
        try? await Task.sleep(for: .seconds(1))
        await coordinator.runPending()
    }

    let firstHalfGaps = report.gapsBeforeBoundary
    let secondHalfGaps = report.gapsAfterBoundary
    let overlapSeconds = await observer.secondsOverlapping(start: captureStarted, end: captureEnded)
    let stagesDuringCapture = await observer.stagesStarted(between: captureStarted, and: captureEnded)
    let transcriptStore = TranscriptStore(storeDirectoryURL: transcripts)
    let runs = transcriptStore.runs()
    let completed = runs.filter { $0.job.state == .complete }
    let preexisting = preexistingJobID.flatMap { id in runs.first { $0.job.id == id } }
    // The baseline arm queues nothing, so nothing is owed on the way out.
    let expectedJobs = options.isBaseline ? 0 : options.jobs

    var failures: [String] = []
    /// Reasons the run cannot answer the question, kept apart from reasons it
    /// answered "no". Reporting an unusable measurement as a product failure is
    /// the worse error of the two.
    var inconclusive: [String] = []
    if report.gaps > 0 {
        failures.append("the recording lost \(report.gaps) buffer(s) to a full capture queue")
    }
    for message in report.writeFailures.prefix(3) {
        failures.append("a capture write failed: \(message)")
    }
    // Attribution, only where the instrumentation supports it. The half-split
    // alone cannot tell "transcription cost capture something" from "the second
    // hour was worse than the first"; if no transcription stage ran during the
    // recording, blaming transcription for the difference is a claim this run
    // actively disproves.
    if secondHalfGaps > firstHalfGaps {
        if stagesDuringCapture > 0 {
            failures.append("queued transcription added \(secondHalfGaps - firstHalfGaps) capture gap(s) in the second half")
        } else {
            inconclusive.append("""
            the second half lost \(secondHalfGaps - firstHalfGaps) more buffer(s) than the first, \
            but no transcription stage ran during the recording, so the difference is the machine, not the queue
            """)
        }
    }
    // Space fell throughout, so the second half always writes to a fuller disk
    // than the first. Past a threshold that bias swamps whatever the gate is
    // trying to measure, and the comparison stops meaning anything.
    if environmentAfter.freeBytes < 32 * 1_073_741_824 {
        inconclusive.append("the volume had only \(environmentAfter.freeBytes / 1_073_741_824)GB free at the end; run this gate with real headroom")
    }
    if environmentAfter.swapUsedBytes > 1_073_741_824 {
        inconclusive.append("the machine was swapping (\(environmentAfter.swapUsedBytes / 1_048_576)MB in use); capture stalls here are memory pressure, not the contract")
    }
    if !options.ignoresScheduler, stagesDuringCapture > 0 {
        failures.append("\(stagesDuringCapture) transcription stage(s) started while the recording was running")
    }
    if !options.ignoresScheduler, overlapSeconds > 2 * options.loadSecondsPerStage {
        failures.append("transcription occupied \(Int(overlapSeconds))s of the recording window; a suspended stage should finish and stop")
    }
    if completed.count != expectedJobs {
        failures.append("\(completed.count) of \(expectedJobs) transcription job(s) completed after the recording stopped")
    }
    if let preexisting, preexisting.job.state != .complete {
        failures.append("the job that was running when the recording started ended as \(preexisting.job.state.rawValue), not complete")
    }
    failures.append(contentsOf: queueFailures.value.map { "a midpoint enqueue failed: \($0)" })

    // Where the gaps fell matters more than how many there were: a burst at the
    // midpoint implicates the queue, a rising line implicates the machine. Two
    // half-totals cannot tell those apart, so print the shape whenever there is
    // one — including on an INCONCLUSIVE run, where diagnosing the environment
    // is the only thing the run is still good for.
    let gapShape: String
    if report.gaps == 0 {
        gapShape = ""
    } else {
        let byMinute = report.gapsByMinute.sorted { $0.key < $1.key }
        gapShape = "\n    Gaps by minute:         "
            + byMinute.map { "\($0.key)m:\($0.value)" }.joined(separator: " ")
    }

    print("""

    Buffers archived:       \(report.deliveredBuffers)
    Capture gaps:           \(report.gaps) (first half \(firstHalfGaps), second half \(secondHalfGaps))\(gapShape)
    Environment:            \(environmentBefore.description) -> \(environmentAfter.description)
    Peak queued:            \(report.peakQueuedBytes / 1_024)KB of \(CaptureWriter.maximumQueuedBytes / 1_024)KB
    Late producer wakeups:  \(report.lateWakeups), worst \(Int(report.worstLatenessMilliseconds))ms
    Transcription overlap:  \(Int(overlapSeconds))s of the \(Int(options.seconds))s recording
    Stages during capture:  \(stagesDuringCapture)
    Jobs complete:          \(completed.count) of \(expectedJobs)
    Transcripts written:    \(completed.count { $0.transcript != nil })
    """)

    if let reportURL = options.reportURL {
        let payload: [String: Any] = [
            "seconds": options.seconds,
            "ignoresScheduler": options.ignoresScheduler,
            "jobs": options.jobs,
            "loadSecondsPerStage": options.loadSecondsPerStage,
            "loadThreads": options.loadThreads,
            "loadWorkingSetMegabytes": options.loadWorkingSetMegabytes,
            "deliveredBuffers": report.deliveredBuffers,
            "captureGaps": report.gaps,
            "firstHalfGaps": firstHalfGaps,
            "secondHalfGaps": secondHalfGaps,
            "peakQueuedBytes": report.peakQueuedBytes,
            "lateProducerWakeups": report.lateWakeups,
            "worstProducerLatenessMilliseconds": report.worstLatenessMilliseconds,
            "transcriptionOverlapSeconds": overlapSeconds,
            "stagesDuringCapture": stagesDuringCapture,
            "jobsCompleted": completed.count,
            "failures": failures,
            "inconclusive": inconclusive,
            "isBaseline": options.isBaseline,
            "gapsByMinute": report.gapsByMinute.map { ["minute": $0.key, "gaps": $0.value] }.sorted { ($0["minute"] ?? 0) < ($1["minute"] ?? 0) },
            "freeBytesBefore": environmentBefore.freeBytes,
            "freeBytesAfter": environmentAfter.freeBytes,
            "swapUsedBytesBefore": environmentBefore.swapUsedBytes,
            "swapUsedBytesAfter": environmentAfter.swapUsedBytes,
        ]
        // Written through a temporary file and renamed. A reader that wakes
        // while a plain write is in flight sees a truncated file, and a
        // truncated report is the one failure here that yields a confidently
        // wrong number instead of an obviously missing one.
        try? AtomicReplaceFileWriter().write(
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
            to: reportURL
        )
        print("Report:                 \(reportURL.path)")
    }

    if !inconclusive.isEmpty {
        print("\nINCONCLUSIVE — the environment invalidated this measurement")
        for reason in inconclusive { print("  - \(reason)") }
        for failure in failures { print("  (also) \(failure)") }
        print("""

        The scheduler assertions this run *can* answer: \(stagesDuringCapture) stage(s) during capture, \
        \(Int(overlapSeconds))s overlap, \(completed.count) of \(expectedJobs) job(s) completed after it.
        Re-run with `--baseline` to confirm the environment, then on a quiet machine with disk headroom.
        """)
        return 2
    }
    guard failures.isEmpty else {
        print("\nFAIL")
        for failure in failures { print("  - \(failure)") }
        return 1
    }
    print("\nPASS")
    return 0
}

/// A short real WAV so the importer, the snapshot service, and the fingerprint
/// all work on genuine media rather than on bytes named `.wav`.
func writeSource(named name: String, in directory: URL) throws -> URL {
    let url = directory.appending(path: name)
    guard !FileManager.default.fileExists(atPath: url.path) else { return url }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let frames = AVAudioFrameCount(48_000 * 4)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let seed = Float(abs(name.hashValue % 97) + 1) * 0.001
    for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = sin(Float(frame) * seed) * 0.4 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

/// A tiny mutable box for values the capture callback and the main flow share.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}

// Line-buffered, so a run that is redirected to a file — which every long run
// is — reports progress as it happens and leaves a readable log behind if it is
// killed. Block buffering loses the whole account of a two-hour run.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command == "run" else { usage() }
exit(await run(parse(Array(arguments.dropFirst()))))
