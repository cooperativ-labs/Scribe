import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum ScreenConsumer: String, Sendable {
    /// No `.screen` output is registered and no screen frames are requested.
    case none
    /// Smallest supported low-frame-rate screen configuration, frames discarded on arrival.
    case minimal
}

enum CaptureScope: Sendable {
    case application(bundleIdentifier: String)
    /// An explicit set of bundle identifiers, used by the filter probe to compare a
    /// main-application filter against one that also includes the browser's helper
    /// processes. `label` names the variant in the journal and report.
    case applications(bundleIdentifiers: [String], label: String)
    case allSystemAudio

    var describedScope: String {
        switch self {
        case .application(let identifier): return "application:\(identifier)"
        case .applications(let identifiers, let label): return "applications:\(label)[\(identifiers.joined(separator: "+"))]"
        case .allSystemAudio: return "all-system-audio"
        }
    }
}

struct RecordOptions: Sendable {
    var outputDirectory: URL
    var scope: CaptureScope
    var microphoneDeviceID: String?
    var durationSeconds: Double
    var sampleRate: Int
    var channelCount: Int
    var screenConsumer: ScreenConsumer
    var fallbackToMinimalScreen: Bool
    var startTimeoutSeconds: Double
    var segmentSeconds: Double
    var cpuSampleSeconds: Double
    var watchProcessName: String
}

enum StopReason: String, Sendable {
    case durationElapsed
    case interrupted
    case streamError
    case noAudioBeforeTimeout
}

enum CaptureError: LocalizedError {
    case noDisplay
    case applicationNotRunning(String)
    case shareableContent(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "ScreenCaptureKit reported no display. A content filter always needs a display, even for audio-only capture."
        case .applicationNotRunning(let identifier):
            return "No running application with bundle identifier \(identifier). Start it first, or use --all-system-audio. The harness never silently broadens capture."
        case .shareableContent(let message):
            return "Cannot read shareable content: \(message). This usually means Screen & System Audio Recording permission has not been granted to this binary."
        }
    }
}

/// One `SCStream` with `.audio` and `.microphone` outputs. Sample-handler callbacks
/// only copy buffer data into owned storage and enqueue it; all file and journal work
/// happens on a single serial writer queue.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: RecordOptions
    private let journal: JournalWriter
    private let writerQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.writer", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.audio", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.microphone", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.screen", qos: .utility)
    private let controlQueue = DispatchQueue(label: "io.cooperativ.scribe.captureharness.control")
    private let lock = NSLock()

    private let systemWriter: TrackWriter
    private let microphoneWriter: TrackWriter

    private var stream: SCStream?
    private var continuation: CheckedContinuation<StopReason, Never>?
    private var settledReason: StopReason?
    private var signalSource: DispatchSourceSignal?
    private var durationTimer: DispatchSourceTimer?
    private var startTimeoutTimer: DispatchSourceTimer?
    private var cpuTimer: DispatchSourceTimer?

    private var sequence = 0
    private var screenFramesDiscarded = 0
    private var droppedUnparsedBuffers = 0
    private var streamErrorMessage: String?
    private var startWallSeconds: Double = 0
    private var selfCPU = CPUAccumulator(name: "capture-harness", pid: getpid())
    private var daemonCPU: CPUAccumulator?
    private var observedThreads: Set<String> = []
    private(set) var resolvedFilterDescription = ""
    private(set) var resolvedMicrophoneDescription = ""
    private(set) var activeScreenConsumer: ScreenConsumer

    init(options: RecordOptions, journal: JournalWriter) {
        self.options = options
        self.journal = journal
        self.activeScreenConsumer = options.screenConsumer
        systemWriter = TrackWriter(track: .audio, directory: options.outputDirectory, journal: journal, segmentSeconds: options.segmentSeconds)
        microphoneWriter = TrackWriter(track: .microphone, directory: options.outputDirectory, journal: journal, segmentSeconds: options.segmentSeconds)
        super.init()
    }

    // MARK: - Configuration

    private func makeFilter() async throws -> (SCContentFilter, String) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.shareableContent(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        switch options.scope {
        case .applications(let identifiers, let label):
            let wanted = Set(identifiers)
            let matches = content.applications.filter { wanted.contains($0.bundleIdentifier) }
            guard !matches.isEmpty else { throw CaptureError.applicationNotRunning(identifiers.joined(separator: ", ")) }
            let filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
            let processes = matches.map { "\($0.bundleIdentifier)/\($0.applicationName)(pid \($0.processID))" }.joined(separator: ", ")
            return (filter, "display \(display.displayID) including filter variant '\(label)' resolved to \(matches.count) process(es): \(processes)")
        case .application(let identifier):
            // The plan requires resolving the selected application to its current
            // process at start, and failing loudly rather than broadening capture.
            let matches = content.applications.filter { $0.bundleIdentifier == identifier }
            guard !matches.isEmpty else { throw CaptureError.applicationNotRunning(identifier) }
            let filter = SCContentFilter(display: display, including: matches, exceptingWindows: [])
            let processes = matches.map { "\($0.applicationName)(pid \($0.processID))" }.joined(separator: ", ")
            return (filter, "display \(display.displayID) including \(identifier) resolved to \(matches.count) process(es): \(processes)")
        case .allSystemAudio:
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            return (filter, "display \(display.displayID) including all applications (all system audio)")
        }
    }

    private func makeConfiguration(screenConsumer: ScreenConsumer) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = options.sampleRate
        configuration.channelCount = options.channelCount
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = options.microphoneDeviceID
        switch screenConsumer {
        case .none:
            // No screen output is registered. Keep the frame configuration small so a
            // stream that insists on producing frames costs as little as possible.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
        case .minimal:
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.showsCursor = false
        }
        return configuration
    }

    // MARK: - Lifecycle

    func start() async throws {
        let (filter, description) = try await makeFilter()
        resolvedFilterDescription = description
        resolvedMicrophoneDescription = MicrophoneCatalog.describe(deviceID: options.microphoneDeviceID)
        try await startStream(filter: filter, screenConsumer: activeScreenConsumer)
        installTimers()
    }

    private func startStream(filter: SCContentFilter, screenConsumer: ScreenConsumer) async throws {
        let configuration = makeConfiguration(screenConsumer: screenConsumer)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
        if screenConsumer == .minimal {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        }
        try await stream.startCapture()
        lock.withLock {
            self.stream = stream
            self.activeScreenConsumer = screenConsumer
        }
        startWallSeconds = ProcessInfo.processInfo.systemUptime
        journal.appendEvent([
            "record": "stream-started",
            "screenConsumer": screenConsumer.rawValue,
            "filter": resolvedFilterDescription,
            "microphone": resolvedMicrophoneDescription,
            "requestedSampleRate": options.sampleRate,
            "requestedChannelCount": options.channelCount,
            "excludesCurrentProcessAudio": true,
            "screenOutputRegistered": screenConsumer == .minimal,
        ])
    }

    private func installTimers() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: controlQueue)
        source.setEventHandler { [weak self] in self?.settle(.interrupted) }
        source.resume()
        signalSource = source

        if options.durationSeconds > 0 {
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + options.durationSeconds)
            timer.setEventHandler { [weak self] in self?.settle(.durationElapsed) }
            timer.resume()
            durationTimer = timer
        }

        if options.startTimeoutSeconds > 0 {
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now() + options.startTimeoutSeconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.writerQueue.sync {
                    if self.systemWriter.bufferCount == 0 && self.microphoneWriter.bufferCount == 0 {
                        self.settle(.noAudioBeforeTimeout)
                    }
                }
            }
            timer.resume()
            startTimeoutTimer = timer
        }

        if options.cpuSampleSeconds > 0 {
            if let pid = ResourceSampler.findProcess(named: options.watchProcessName) {
                daemonCPU = CPUAccumulator(name: options.watchProcessName, pid: pid)
            }
            let timer = DispatchSource.makeTimerSource(queue: controlQueue)
            timer.schedule(deadline: .now(), repeating: options.cpuSampleSeconds)
            timer.setEventHandler { [weak self] in self?.sampleResources() }
            timer.resume()
            cpuTimer = timer
        }
    }

    private func sampleResources() {
        let wall = ProcessInfo.processInfo.systemUptime - startWallSeconds
        var event: [String: Any] = ["record": "resource-sample", "elapsedSeconds": wall]
        if let sample = ResourceSampler.selfSample() {
            selfCPU.record(sample, wallSeconds: wall)
            event["harnessCPUSeconds"] = sample.cpuSeconds
            event["harnessPhysFootprintBytes"] = sample.physFootprintBytes
        }
        if var daemon = daemonCPU, let sample = ResourceSampler.sample(pid: daemon.pid, name: daemon.name) {
            daemon.record(sample, wallSeconds: wall)
            daemonCPU = daemon
            event["\(daemon.name)CPUSeconds"] = sample.cpuSeconds
            event["\(daemon.name)PhysFootprintBytes"] = sample.physFootprintBytes
        }
        journal.appendEvent(event)
    }

    /// Restart the stream with a minimal low-frame-rate screen configuration after
    /// audio-only operation produced nothing. Answers the feasibility question directly.
    func retryWithMinimalScreen() async throws {
        journal.appendEvent(["record": "retry", "reason": "no audio buffers arrived without a screen consumer"])
        await stopStreamOnly()
        lock.withLock { settledReason = nil }
        let (filter, description) = try await makeFilter()
        resolvedFilterDescription = description
        try await startStream(filter: filter, screenConsumer: .minimal)
        installTimers()
    }

    func waitForStop() async -> StopReason {
        await withCheckedContinuation { (continuation: CheckedContinuation<StopReason, Never>) in
            lock.lock()
            if let settledReason {
                lock.unlock()
                continuation.resume(returning: settledReason)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func settle(_ reason: StopReason) {
        lock.lock()
        guard settledReason == nil else { lock.unlock(); return }
        settledReason = reason
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: reason)
    }

    private func stopStreamOnly() async {
        signalSource?.cancel(); signalSource = nil
        durationTimer?.cancel(); durationTimer = nil
        startTimeoutTimer?.cancel(); startTimeoutTimer = nil
        cpuTimer?.cancel(); cpuTimer = nil
        let active = lock.withLock { () -> SCStream? in let current = stream; stream = nil; return current }
        if let active {
            do { try await active.stopCapture() }
            catch { journal.appendEvent(["record": "stop-error", "message": error.localizedDescription]) }
        }
    }

    /// Stops the stream, then drains the writer queue before closing files, so no
    /// buffer that already reached a callback is lost.
    func stop(reason: StopReason) async -> CaptureReport {
        sampleResources()
        await stopStreamOnly()
        let wall = ProcessInfo.processInfo.systemUptime - startWallSeconds
        let (consumer, streamError) = lock.withLock { (activeScreenConsumer, streamErrorMessage) }
        return writerQueue.sync {
            systemWriter.finish()
            microphoneWriter.finish()
            journal.appendEvent(["record": "stream-stopped", "reason": reason.rawValue, "elapsedSeconds": wall])
            return CaptureReport(
                reason: reason,
                elapsedSeconds: wall,
                screenConsumer: consumer,
                screenFramesDiscarded: screenFramesDiscarded,
                droppedUnparsedBuffers: droppedUnparsedBuffers,
                streamErrorMessage: streamError,
                filterDescription: resolvedFilterDescription,
                microphoneDescription: resolvedMicrophoneDescription,
                callbackThreads: observedThreads.sorted(),
                system: TrackSummary(writer: systemWriter),
                microphone: TrackSummary(writer: microphoneWriter),
                selfCPU: selfCPU.summary(overWallSeconds: wall),
                daemonCPU: daemonCPU?.summary(overWallSeconds: wall)
            )
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); streamErrorMessage = error.localizedDescription; lock.unlock()
        journal.appendEvent(["record": "stream-error", "message": error.localizedDescription])
        settle(.streamError)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            writerQueue.async { [weak self] in self?.screenFramesDiscarded += 1 }
            return
        case .audio:
            handleAudio(sampleBuffer, track: .audio)
        case .microphone:
            handleAudio(sampleBuffer, track: .microphone)
        @unknown default:
            return
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, track: TrackKind) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbdPointer) else {
            writerQueue.async { [weak self] in self?.droppedUnparsedBuffers += 1 }
            return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let owned = CopyOut.pcmBuffer(from: sampleBuffer, format: format, frames: frames) else {
            writerQueue.async { [weak self] in self?.droppedUnparsedBuffers += 1 }
            return
        }

        var layoutSize = 0
        let layoutTag = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize)?.pointee.mChannelLayoutTag
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let threadLabel = CallbackThread.currentDescription()
        let hostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds

        lock.lock()
        sequence += 1
        let sequenceNumber = sequence
        lock.unlock()

        let captured = CapturedBuffer(
            track: track,
            pcm: owned,
            format: asbdPointer.pointee,
            channelLayoutTag: layoutTag,
            ptsValue: pts.value,
            ptsTimescale: pts.timescale,
            frameCount: frames,
            sequence: sequenceNumber,
            callbackThread: threadLabel,
            callbackHostSeconds: hostSeconds
        )
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.observedThreads.insert("\(track.rawValue): \(threadLabel)")
            switch track {
            case .audio: self.systemWriter.write(captured)
            case .microphone: self.microphoneWriter.write(captured)
            }
        }
    }
}

enum CallbackThread {
    static func currentDescription() -> String {
        let label = String(cString: __dispatch_queue_get_label(nil))
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        return "queue=\(label) tid=\(threadID) main=\(Thread.isMainThread) qos=\(qos_class_self().rawValue)"
    }
}

enum CopyOut {
    /// Copies the sample buffer's audio into a newly allocated `AVAudioPCMBuffer`.
    /// The retained block buffer is released when this function returns, so no
    /// no-copy pointer ever outlives its backing sample buffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        destination.frameLength = AVAudioFrameCount(frames)

        let bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let listSize = MemoryLayout<AudioBufferList>.size + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let source = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer { free(source.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: source.unsafeMutablePointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard target.count == source.count else { return nil }
        for index in 0..<source.count {
            guard let sourceData = source[index].mData, let targetData = target[index].mData else { return nil }
            let bytes = min(Int(source[index].mDataByteSize), Int(target[index].mDataByteSize))
            memcpy(targetData, sourceData, bytes)
            target[index].mDataByteSize = UInt32(bytes)
        }
        return destination
    }
}
