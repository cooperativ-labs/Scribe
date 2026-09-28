@preconcurrency import AVFoundation
import AppKit
import Assist
import Combine
import Foundation

public enum DictationState: Sendable, Equatable {
    case idle
    case warming
    case listening(level: Float)
    case transcribing
    case inserted(String?)
    /// A paste was posted into an app whose text field is inaccessible to AX.
    /// The transcript remains on the clipboard because insertion is unverified.
    case unverifiedPaste
    case copied
    case error(String)
    /// The assistant's request is in flight: the provider ("ChatGPT") and the model.
    case thinking(assistant: String, model: String?)
    /// No selection, no fresh clipboard and no window text in the named app.
    case nothingToWorkWith(String?)
    /// The ChatGPT sign-in is missing or expired; the indicator offers Sign in.
    case signInRequired(String)
}

/// What the assistant needs at key-down, resolved from Settings by the host.
public struct AssistantConfiguration: Sendable {
    public var assistant: any TextAssistant
    /// Shown while thinking, e.g. "GPT-6 Luna (light)".
    public var modelName: String?
    public var sources: SourceTextOptions
    /// The Result setting: leave the answer on the clipboard instead of inserting it.
    public var copyOnly: Bool

    public init(assistant: any TextAssistant, modelName: String?, sources: SourceTextOptions, copyOnly: Bool) {
        self.assistant = assistant
        self.modelName = modelName
        self.sources = sources
        self.copyOnly = copyOnly
    }
}

public enum AssistantAvailability: Sendable {
    case ready(AssistantConfiguration)
    /// No usable account; the message says what to set up.
    case needsAccount(String)
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
    /// The current session is waiting for a cold helper to load the model.
    private var warmingForSession = false
    private var active = false
    private var generation = 0
    private var appliedPolicy: (keepLoaded: Bool, idleMinutes: Int)?
    private var startedInApplication: pid_t?
    private let focusLocator = FocusedFieldLocator()
    private var startingFocus: Task<FocusedFieldSnapshot?, Never>?

    /// Which mode the current or last session belongs to.
    @Published public private(set) var intent: DictationIntent = .dictation
    /// The listening hint naming the sources found, once gathering finishes.
    @Published public private(set) var assistantHint: String?
    /// Resolved at each assistant key-down; nil means the assistant is not wired.
    public var assistantAvailability: (@MainActor () -> AssistantAvailability)?
    public var assistantTimeout: Duration = .seconds(60)
    private let sourceCollector = SourceTextCollector()
    private var clipboardFreshness = ClipboardFreshness()
    private var assistantSession: AssistantConfiguration?
    private var startedApplicationName: String?
    private var sourcesTask: Task<GatheredSources, Never>?

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
        // Both modes share the model, which is installed from Dictation settings.
        intent = .dictation
        state = .error("Loading model is unavailable. Download it in Dictation Settings.")
    }

    public func setSecureInputBlocked(_ blocked: Bool) {
        if blocked {
            cancel()
            intent = .dictation
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
        case .listeningStarted(let mode, let intent):
            stopPreview()
            transcriptionTask?.cancel()
            sourcesTask?.cancel()
            sourcesTask = nil
            generation += 1
            triggerMode = mode
            self.intent = intent
            assistantHint = nil
            assistantSession = nil
            let frontmost = NSWorkspace.shared.frontmostApplication
            startedInApplication = frontmost?.processIdentifier
            startedApplicationName = frontmost?.localizedName
            if intent == .assistant {
                switch assistantAvailability?() ?? .needsAccount("Voice Assistant is not available.") {
                case .needsAccount(let message):
                    cancel()
                    state = .signInRequired(message)
                    return
                case .ready(let configuration):
                    assistantSession = configuration
                    startGathering(configuration.sources)
                }
            }
            if let pid = startedInApplication {
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                let screens = NSScreen.screens.map(\.frame)
                startingFocus = Task { [focusLocator] in
                    await focusLocator.locate(frontmostPID: pid, screenTop: screenTop, screens: screens)
                }
            }
            do {
                try capture.start(microphoneID: microphoneID)
                // The preview shows dictated text; an instruction is not inserted.
                let preview = livePreviewEnabled && intent == .dictation
                livePreview = preview ? "Listening for speech…" : nil
                state = .listening(level: 0)
                if preview { startPreview() }
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
            let assistant = intent == .assistant ? assistantSession : nil
            transcriptionTask = Task { [weak self, engine] in
                var runDirectory: URL?
                defer { if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) } }
                do {
                    // A cold helper spends tens of seconds mapping the model and
                    // compiling for the Neural Engine; call that what it is.
                    if !(await engine.isReady()) {
                        guard let self, self.generation == currentGeneration else { return }
                        self.warmingForSession = true
                        self.state = .warming
                        defer { self.warmingForSession = false }
                        try await engine.warm()
                        guard self.generation == currentGeneration, !Task.isCancelled else { return }
                        self.state = .transcribing
                    }
                    let directory = FileManager.default.temporaryDirectory.appending(path: "ScribeDictation-\(UUID().uuidString)", directoryHint: .isDirectory)
                    runDirectory = directory
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let audioURL = directory.appending(path: "dictation.wav")
                    try Self.writeWAV(samples, to: audioURL)
                    let result = try await engine.dictate(audioURL: audioURL, runDirectoryURL: directory, language: language)
                    guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                    if result.hasSpeech, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if let assistant {
                            await self.runAssistant(instruction: result.text, configuration: assistant, generation: currentGeneration)
                            return
                        }
                        let outcome = await self.insertTrackingClipboard { await self.inserter.insertDictation(result.text) }
                        guard self.generation == currentGeneration, !Task.isCancelled else { return }
                        await self.report(outcome)
                    } else {
                        self.state = .idle
                    }
                } catch {
                    guard let self, self.generation == currentGeneration else { return }
                    self.state = Self.transcriptionState(for: error)
                }
            }
        case .cancelled(let reason, _):
            cancel()
            if reason == .maximumDuration {
                state = .error("Maximum dictation length reached. Start a new dictation to continue.")
            }
        case .secureInputBlocked:
            cancel()
            state = .error("Dictation is paused while Secure Keyboard Entry is on")
        }
    }

    /// The indicator's ✕ once the key is released: the model loading for this
    /// session, the transcription, or the assistant's request. Returns false
    /// when there was nothing to cancel.
    @discardableResult
    public func cancelPendingRequest() -> Bool {
        switch state {
        case .transcribing, .thinking: cancel(); return true
        case .warming where warmingForSession: cancel(); return true
        default: return false
        }
    }

    /// Escape after the assistant key is released. Escape is left alone for
    /// dictation, where an ordinary press would discard the words just spoken.
    @discardableResult
    public func cancelAssistantRequest() -> Bool {
        guard intent == .assistant else { return false }
        return cancelPendingRequest()
    }

    /// The engine only cancels a request it could not keep; the person is
    /// told to try again rather than shown Swift's CancellationError text.
    nonisolated static func transcriptionState(for error: any Error) -> DictationState {
        if error is CancellationError {
            return .error("Dictation was interrupted before it finished. Try again.")
        }
        return .error(error.localizedDescription)
    }

    public func cancel() {
        stopPreview()
        generation += 1
        warmingForSession = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sourcesTask?.cancel()
        sourcesTask = nil
        assistantHint = nil
        levelTimer?.invalidate()
        levelTimer = nil
        capture.stop()
        startingFocus?.cancel()
        startingFocus = nil
        state = .idle
    }

    // MARK: Assistant

    /// Reads the clipboard here, on the main actor, and leaves the
    /// Accessibility walk to the collector so it runs while the person speaks.
    private func startGathering(_ options: SourceTextOptions) {
        let pasteboard = NSPasteboard.general
        let fresh = clipboardFreshness.take(changeCount: pasteboard.changeCount)
        let clipboardText = options.usesCopiedText && fresh ? pasteboard.string(forType: .string) : nil
        let pid = startedInApplication ?? getpid()
        let session = generation
        let applicationName = startedApplicationName
        let task = Task { [sourceCollector] in
            await sourceCollector.collect(pid: pid, clipboardText: clipboardText, options: options)
        }
        sourcesTask = task
        Task { [weak self] in
            let sources = await task.value
            guard let self, self.generation == session, case .listening = self.state else { return }
            self.assistantHint = sources.hint(applicationName: applicationName)
        }
    }

    private func runAssistant(instruction: String, configuration: AssistantConfiguration, generation session: Int) async {
        let sources = await sourcesTask?.value ?? GatheredSources()
        guard generation == session, !Task.isCancelled else { return }
        guard !sources.isEmpty else {
            state = .nothingToWorkWith(startedApplicationName)
            return
        }
        state = .thinking(assistant: configuration.assistant.displayName, model: configuration.modelName)
        let request = sources.request(instruction: instruction, applicationName: startedApplicationName)
        do {
            let assistant = configuration.assistant
            let response = try await Self.withTimeout(assistantTimeout) { try await assistant.respond(to: request) }
            guard generation == session, !Task.isCancelled else { return }
            let outcome = await insertTrackingClipboard {
                await self.inserter.insertGenerated(response.text, copyOnly: configuration.copyOnly)
            }
            guard generation == session, !Task.isCancelled else { return }
            await report(outcome)
        } catch {
            guard generation == session, !Task.isCancelled, !(error is CancellationError) else { return }
            state = Self.assistantState(for: error, timeout: assistantTimeout)
        }
    }

    nonisolated static func assistantState(for error: any Error, timeout: Duration) -> DictationState {
        switch error {
        case AssistError.signInRequired:
            .signInRequired(AssistError.signInRequired.localizedDescription)
        case is AssistantTimeout:
            .error("No answer after \(timeout.components.seconds) seconds. Try again.")
        default:
            .error(error.localizedDescription)
        }
    }

    struct AssistantTimeout: Error {}

    /// Runs `body`, failing with `AssistantTimeout` after `limit`. Cancelling
    /// the caller cancels the request, which is how Escape reaches the HTTP task.
    nonisolated static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw AssistantTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    /// Scribe's own paste fallback and copy-only answers change the clipboard;
    /// that must not make it look freshly copied at the next assistant request.
    private func insertTrackingClipboard(_ insert: () async -> DictationInsertionOutcome) async -> DictationInsertionOutcome {
        let before = NSPasteboard.general.changeCount
        let outcome = await insert()
        clipboardFreshness.adoptOwnChange(before: before, after: NSPasteboard.general.changeCount)
        return outcome
    }

    private func report(_ outcome: DictationInsertionOutcome) async {
        switch outcome {
        case .accessibility, .pasted:
            let currentApp = NSWorkspace.shared.frontmostApplication
            let currentPID = currentApp?.processIdentifier
            let originalField = await startingFocus?.value
            var moved = currentPID != startedInApplication
            if !moved, let originalField, let currentPID {
                moved = !(await focusLocator.stillFocused(originalField, frontmostPID: currentPID))
            }
            state = .inserted(moved ? currentApp?.localizedName : nil)
        case .unverifiedPaste: state = .unverifiedPaste
        case .copied: state = .copied
        case .discarded: state = .idle
        }
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
