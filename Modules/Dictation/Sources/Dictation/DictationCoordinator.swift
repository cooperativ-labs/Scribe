@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation

public enum DictationState: Sendable, Equatable {
    case idle
    case warming
    case listening(level: Float)
    case transcribing
    case inserted(String?)
    case copied
    case error(String)
}

/// The foreground dictation path. It never enters the durable transcription
/// outbox, background scheduler, or meeting recording capture pipeline.
@MainActor
public final class DictationCoordinator: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var triggerMode: DictationTriggerMode = .hold
    @Published public private(set) var livePreview: String?
    public var livePreviewEnabled = false
    private var previewTask: Task<Void, Never>?
    private let engine: DictationEngine
    private let inserter: DictationTextInserter
    private let capture = DictationAudioCapture()
    private var levelTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    private var active = false
    private var generation = 0
    private var appliedPolicy: (keepLoaded: Bool, idleMinutes: Int)?
    private var startedInApplication: pid_t?
    private let focusLocator = FocusedFieldLocator()
    private var startingFocus: Task<FocusedFieldSnapshot?, Never>?

    public var microphoneID: String?
    public var language = "automatic"
    public var keepModelLoaded = true
    public var idleUnloadMinutes = 10

    public init(engine: DictationEngine, inserter: DictationTextInserter = DictationTextInserter()) {
        self.engine = engine
        self.inserter = inserter
        capture.onRecoveryFailure = { [weak self] message in
            self?.cancel()
            self?.state = .error(message)
        }
    }

    public func showModelUnavailable() {
        state = .error("Loading model is unavailable. Download it in Dictation Settings.")
    }

    public func setSecureInputBlocked(_ blocked: Bool) {
        if blocked {
            cancel()
            state = .error("Dictation is paused while Secure Keyboard Entry is on")
        } else if state == .error("Dictation is paused while Secure Keyboard Entry is on") {
            state = .idle
        }
    }

    public var textOptions: DictationTextOptions {
        get { inserter.options }
        set { inserter.options = newValue }
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled == active {
            if enabled, appliedPolicy?.keepLoaded != keepModelLoaded ||
                        appliedPolicy?.idleMinutes != idleUnloadMinutes {
                appliedPolicy = (keepModelLoaded, idleUnloadMinutes)
                Task { [engine, keepModelLoaded, idleUnloadMinutes] in
                    await engine.configure(keepLoaded: keepModelLoaded, idleMinutes: idleUnloadMinutes)
                }
            }
            return
        }
        active = enabled
        if enabled {
            appliedPolicy = (keepModelLoaded, idleUnloadMinutes)
            state = .warming
            Task { [weak self, engine, keepModelLoaded, idleUnloadMinutes] in
                await engine.configure(keepLoaded: keepModelLoaded, idleMinutes: idleUnloadMinutes)
                do {
                    try await engine.warm()
                    if self?.active == true {
                        if self?.state == .warming { self?.state = .idle }
                    } else {
                        await engine.unload()
                    }
                } catch { self?.state = .error(error.localizedDescription) }
            }
        } else {
            appliedPolicy = nil
            cancel()
            Task { await engine.unload() }
        }
    }

    public func consume(_ event: DictationTriggerEvent) {
        switch event {
        case .listeningStarted(let mode):
            stopPreview()
            transcriptionTask?.cancel()
            generation += 1
            triggerMode = mode
            startedInApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let pid = startedInApplication {
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let screens = NSScreen.screens.map(\.frame)
                startingFocus = Task { [focusLocator] in
                    await focusLocator.locate(frontmostPID: pid, screenTop: screenTop, screens: screens)
                }
            }
            do {
                try capture.start(microphoneID: microphoneID)
                livePreview = livePreviewEnabled ? "Listening for speech…" : nil
                state = .listening(level: 0)
                if livePreviewEnabled { startPreview() }
                levelTimer?.invalidate()
                levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.capture.isRecording else { return }
                        self.state = .listening(level: self.capture.level)
                    }
                }
            } catch { state = .error(error.localizedDescription) }
        case .listeningEnded:
            guard capture.isRecording else { return }
            stopPreview()
            levelTimer?.invalidate()
            levelTimer = nil
            let samples: [Float]
            do { samples = try capture.finish() }
            catch { state = .error(error.localizedDescription); return }
            state = .transcribing
            let currentGeneration = generation
            let language = self.language
            transcriptionTask = Task { [weak self, engine] in
                var runDirectory: URL?
                defer { if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) } }
                do {
                    let directory = FileManager.default.temporaryDirectory.appending(path: "ScribeDictation-\(UUID().uuidString)", directoryHint: .isDirectory)
                    runDirectory = directory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let audioURL = directory.appending(path: "dictation.wav")
                    try Self.writeWAV(samples, to: audioURL)
                    let result = try await engine.dictate(audioURL: audioURL, runDirectoryURL: directory, language: language)
                    guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                    if result.hasSpeech, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let outcome = await self.inserter.insertDictation(result.text)
                        guard self.generation == currentGeneration, !Task.isCancelled else { return }
                        switch outcome {
                        case .accessibility, .pasted:
                            let currentApp = NSWorkspace.shared.frontmostApplication
                            let currentPID = currentApp?.processIdentifier
                            let originalField = await self.startingFocus?.value
                            var moved = currentPID != self.startedInApplication
                            if !moved, let originalField, let currentPID {
                                moved = !(await self.focusLocator.stillFocused(originalField, frontmostPID: currentPID))
                            }
                            self.state = .inserted(moved ? currentApp?.localizedName : nil)
                        case .copied: self.state = .copied
                        case .discarded: self.state = .idle
                        }
                    } else {
                        self.state = .idle
                    }
                } catch {
                    guard let self, self.generation == currentGeneration else { return }
                    self.state = .error(error.localizedDescription)
                }
            }
        case .cancelled(let reason):
            cancel()
            if reason == .maximumDuration {
                state = .error("Maximum dictation length reached. Start a new dictation to continue.")
            }
        case .secureInputBlocked:
            cancel()
            state = .error("Dictation is paused while Secure Keyboard Entry is on")
        }
    }

    public func cancel() {
        stopPreview()
        generation += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        levelTimer?.invalidate()
        levelTimer = nil
        capture.stop()
        startingFocus?.cancel()
        startingFocus = nil
        state = .idle
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        livePreview = nil
    }

    private func startPreview() {
        let session = generation
        let language = self.language
        previewTask = Task { [weak self, engine] in
            // One bounded request at a time; slow inference never builds a queue.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard let self, self.generation == session, self.capture.isRecording else { return }
                let samples = self.capture.previewSamples()
                guard samples.count >= 8_000 else { continue }
                let directory = FileManager.default.temporaryDirectory.appending(
                    path: "ScribeDictationPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let audio = directory.appending(path: "preview.wav")
                    try Self.writeWAV(samples, to: audio)
                    let result = try await engine.dictate(audioURL: audio, runDirectoryURL: directory, language: language)
                    guard !Task.isCancelled, self.generation == session, self.capture.isRecording else { return }
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.livePreview = result.hasSpeech && !text.isEmpty ? text : "Listening for speech…"
                } catch {
                    guard !Task.isCancelled, self.generation == session, self.capture.isRecording else { return }
                    self.livePreview = "Preview unavailable. Final transcription will run when you stop."
                    return
                }
            }
        }
    }

    private static func writeWAV(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw DictationCaptureError.conversionFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
