import AppKit
import Capture
import Combine
import Dictation
import Platform
import Processing
import ScribeAppCore
import ScribeUI
import Speakers
import Storage
import SwiftUI
import Transcription
import Vocabulary

/// Owns the objects the menu, the settings window, and the app delegate share.
///
/// The menu talks only through `RecordingCoordinating`; the live implementation
/// translates that presentation contract into the capture actor's durable state.
@MainActor
final class ScribeAppEnvironment: ObservableObject {
    let settings: ScribeSettings
    let coordinator: LiveRecordingCoordinator
    let menuModel: RecorderMenuModel
    let permissions: PermissionService
    /// Watches the chosen applications for a call in progress. Runs for the life
    /// of the app; what it finds is offered to the person, never acted on alone.
    let meetingDetector: MeetingDetector
    /// The chip that offers to record a noticed call, and becomes its transport
    /// once one is running. Owns no detection of its own: it is told what was
    /// found and decides only what to show.
    let meetingChipModel: MeetingChipModel
    /// The person's Apple Calendar, once they connect it. Names recordings,
    /// transcripts, and the chip's offer after the meeting in progress.
    let calendar: CalendarMeetingService
    @Published private(set) var detectedMeeting: DetectedMeeting?
    private let processingQueue: ProcessingQueue?
    private let outbox: TranscriptionRequestOutbox
    /// Absent only when the transcript store cannot be opened at all; the
    /// recorder is unaffected either way.
    let transcription: TranscriptionHostService?
    /// The custom transcription vocabulary. Absent only when its store could
    /// not be opened, in which case Settings hides the section.
    let vocabulary: VocabularyViewModel?
    /// Lets the transcript window ask Settings to open at the vocabulary.
    let settingsFocus = SettingsFocusModel()
    /// Turns a reviewed transcript into a Latch session running a coding agent
    /// in a folder the person connected.
    let agentHandoff: AgentHandoffService
    /// Set by the app delegate, which owns the settings window.
    var openSettingsWindow: (() -> Void)?
    /// Mirrors the transcription service's status into the menu.
    @Published private(set) var transcriptionStatus = TranscriptionHostService.Status()
    @Published private(set) var updateState: UpdateMenuState = .idle {
        didSet {
            guard oldValue != updateState else { return }
            if case .failed(let message) = updateState {
                MessageDebugLog.shared.record(message, source: "Updates", level: .error)
            }
        }
    }
    private var transcriptWindow: NSWindow?
    private var speakersWindow: NSWindow?
    /// The floating notes panel, made the first time it is opened.
    private(set) var meetingNotesPanel: MeetingNotesPanelController?
    /// Says briefly why a command had nothing to act on. Set by the app
    /// delegate, which owns the status item the hint hangs from.
    var showHint: ((String) -> Void)?

    private let triggerMonitor = DictationTriggerMonitor()
    private(set) var dictationCoordinator: DictationCoordinator?
    private var triggerSettingsObservation: AnyCancellable?
    private var assistantAccountObservation: AnyCancellable?
    nonisolated(unsafe) private var dictationPermissionTimer: Timer?
    private let hotkeys: HotkeyService
    private var firstRunWindow: NSWindow?
    private var selectionObservation: RecorderObservationToken?
    private var queueEventTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private let updater = ApplicationUpdater()
    private var preparedUpdate: ApplicationUpdater.PreparedUpdate?
    /// Sessions this launch adopted rather than started, so the recovery notice
    /// can be retired once the last one is finished with.
    private var adoptedSessionIDs: Set<UUID> = []
    /// The subset whose raw capture had to be repaired, which is a stronger fact
    /// than merely finding processing left over, and is worded differently.
    private var repairedSessionIDs: Set<UUID> = []

    init() {
        // Load the opt-in flag before any startup messages can be emitted.
        _ = MessageDebugLog.shared
        let settings = ScribeSettings()
        let permissions = PermissionService()
        self.settings = settings
        self.permissions = permissions
        processingQueue = try? ProcessingQueue(configuration: .inRecordingsDirectory(settings.recordingsFolderURL))
        outbox = .inRecordingsDirectory(settings.recordingsFolderURL)
        let calendar = CalendarMeetingService(settings: settings)
        self.calendar = calendar

        let coordinator = LiveRecordingCoordinator(
            snapshot: RecorderSnapshot(
                permissions: permissions.currentStatus(),
                selectedApplicationID: settings.rememberedApplicationBundleIdentifier,
                recordingMode: settings.rememberedRecordingMode,
                selectedMicrophoneID: settings.rememberedMicrophoneID,
                recordingsFolderURL: settings.recordingsFolderURL
            ),
            permissions: permissions,
            sourceProvider: SystemCaptureSourceProvider(),
            openFolder: { NSWorkspace.shared.open($0) },
            scheduler: processingQueue,
            processingSubmission: { [processingQueue] directory, job in
                guard let processingQueue else { return }
                _ = try? await processingQueue.enqueue(sessionDirectory: directory, jobID: job.id)
                await processingQueue.runPending()
            },
            captureActivityHandler: { [processingQueue] active in
                await processingQueue?.setCaptureActive(active)
            },
            recordingTitleProvider: calendar,
            timestampOffset: { TimeInterval(settings.pasteTimestampOffsetSeconds) }
        )
        self.coordinator = coordinator
        menuModel = RecorderMenuModel(
            coordinator: coordinator,
            pasteTimestampShortcut: { settings.pasteTimestampShortcut },
            meetingNotesShortcut: { settings.meetingNotesShortcut }
        )
        meetingChipModel = MeetingChipModel(
            coordinator: coordinator,
            shouldStopWhenMeetingEnds: {
                settings.meetingDetectionEnabled && settings.stopRecordingWhenMeetingEnds
            }
        )
        hotkeys = HotkeyService(coordinator: coordinator)
        meetingDetector = MeetingDetector(settings: settings, titleProvider: calendar)

        transcription = try? TranscriptionHostService(settings: settings, scheduler: processingQueue)
        if let installation = try? WorkerLocator.locate() {
            dictationCoordinator = DictationCoordinator(engine: DictationEngine(
                installation: installation,
                modelsDirectoryProvider: { @MainActor [settings] in settings.modelsFolderURL },
                vocabularySnapshot: { try VocabularyStore.openApplicationSupportLibrary().load().snapshot }
            ))
        }
        vocabulary = VocabularyViewModel.applicationSupportModel()
        agentHandoff = AgentHandoffService(settings: settings)
        // The review window's Send to Agent action reaches Latch through this
        // service; the window itself never launches anything.
        transcription?.agentDispatcher = LatchTranscriptAgentDispatcher(service: agentHandoff)
        // A queued send's notification, clicked, shows its meeting.
        transcription?.revealMeeting = { [weak self] draftID in
            self?.revealMeetingInTranscripts(draftID: draftID)
        }

        // Set here rather than passed in: the review window's Vocabulary button
        // has to reach the settings window, which the app delegate owns.
        if vocabulary != nil {
            transcription?.openVocabularySettings = { [weak self] in self?.openVocabularySettings() }
        }

        coordinator.terminationHandler = { Self.requestTermination() }
        // Each recording gets a meeting draft from the moment capture is
        // active: the placeholder row, its title and, later, its notes.
        coordinator.lifecycleHandler = { [weak self] event in
            self?.recordingLifecycleDidChange(event)
        }
        // A meeting note is stamped with the Paste Timestamp figure for the
        // session being captured, and with nothing while paused or stopped.
        transcription?.noteClock = { [weak coordinator] sessionID in
            guard let state = coordinator?.snapshot.state, state.activity?.sessionID == sessionID else { return nil }
            return RecordingTimestamp.noteOffsetMilliseconds(
                state: state,
                at: Date(),
                offset: TimeInterval(settings.pasteTimestampOffsetSeconds)
            )
        }
        transcription?.publishFinishedRecording = { [weak self] directory, draftID in
            await self?.publishFinishedRecording(sessionDirectory: directory, draftID: draftID)
                ?? "Transcription is not available right now."
        }
        coordinator.recoveryReporter = { [weak self] recovered in
            self?.reportRepairedCaptures(recovered)
        }
        hotkeys.openMeetingNotes = { [weak self] in self?.openLiveMeetingNotes() }
        registerShortcuts()
        observeProcessingQueue()
        adoptWorkFoundAtLaunch()
        transcription?.start { [weak self] status in
            self?.transcriptionStatus = status
        }

        // Source choices made in the menu are the ones Settings remembers.
        selectionObservation = coordinator.observeSnapshot { [weak self] (snapshot: RecorderSnapshot) in
            guard let self else { return }
            self.settings.rememberedApplicationBundleIdentifier = snapshot.selectedApplicationID
            self.settings.rememberedMicrophoneID = snapshot.selectedMicrophoneID
            self.settings.rememberedRecordingMode = snapshot.recordingMode
        }

        // Detection only reports. The chip turns that report into an offer and,
        // when the person opted in, finishes the recording it started after the
        // detector's end-of-call grace period has elapsed.
        meetingDetector.onChange = { [weak self] meeting in
            self?.detectedMeeting = meeting
            self?.meetingChipModel.meetingWasDetected(meeting)
        }
        meetingDetector.start()
        triggerMonitor.onEvent = { [weak self] event in
            self?.dictationCoordinator?.consume(event)
        }
        // Escape reaches an assistant request after its key is released too.
        triggerMonitor.onEscape = { [weak self] in
            self?.dictationCoordinator?.cancelAssistantRequest()
        }
        dictationCoordinator?.assistantAvailability = { [weak self] in
            self?.assistantAvailability() ?? .needsAccount("Voice Assistant is not available.")
        }
        // The sign-in state is read from the Keychain once, when the assistant
        // is on, so the first press after launch already knows the account.
        assistantAccountObservation = settings.$assistantEnabled
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await VoiceAssistantAccount.shared.load(settings: self.settings)
                }
            }
        triggerMonitor.onSecureInputChange = { [weak self] blocked in
            self?.settings.setDictationSecureInputBlocked(blocked)
            self?.dictationCoordinator?.setSecureInputBlocked(blocked)
        }
        triggerMonitor.onActivationKeyObserved = { [weak self] intent in
            switch intent {
            case .dictation: self?.settings.noteDictationKey()
            case .assistant: self?.settings.noteAssistantKey()
            }
        }
        triggerSettingsObservation = settings.$dictationEnabled
            .combineLatest(settings.$dictationActivationKey, settings.$dictationLivePreview)
            .map { _ in () }
            .merge(with: settings.$assistantEnabled.combineLatest(settings.$assistantActivationKey).map { _ in () })
            .sink { [weak self] in
                Task { @MainActor [weak self] in self?.syncTriggerMonitors() }
            }
        dictationPermissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTriggerMonitors() }
        }
        syncTriggerMonitors()
    }

    deinit {
        queueEventTask?.cancel()
        updateTask?.cancel()
        dictationPermissionTimer?.invalidate()
    }

    /// Installs the dictation key and the assistant key for whichever of the
    /// two is on. Both need the dictation model and the same permissions, so
    /// the model stays warm while either is enabled.
    private func syncTriggerMonitors() {
        var modelUnavailable = false
        if settings.dictationEnabled || settings.assistantEnabled {
            switch settings.modelInstaller.state {
            case .notInstalled, .failed:
                settings.dictationEnabled = false
                settings.assistantEnabled = false
                modelUnavailable = true
            case .checking, .installing, .installed:
                break
            }
        }
        guard settings.dictationEnabled || settings.assistantEnabled, settings.modelInstaller.state == .installed,
              permissions.dictationAccess().isReady else {
            triggerMonitor.stop()
            dictationCoordinator?.setEnabled(false)
            if modelUnavailable { dictationCoordinator?.showModelUnavailable() }
            return
        }
        guard let dictationCoordinator else {
            triggerMonitor.stop()
            NSLog("Dictation is enabled but the transcription worker is unavailable")
            return
        }
        dictationCoordinator.microphoneID = settings.rememberedMicrophoneID
        dictationCoordinator.livePreviewEnabled = settings.dictationLivePreview
        dictationCoordinator.language = settings.dictationLanguage
        dictationCoordinator.keepModelLoaded = settings.dictationKeepModelLoaded
        dictationCoordinator.idleUnloadMinutes = settings.dictationIdleUnloadMinutes
        dictationCoordinator.textOptions = DictationTextOptions(
            leadingSpace: settings.dictationLeadingSpace,
            trailingSpace: settings.dictationTrailingSpace,
            restoreClipboard: settings.dictationRestoreClipboard
        )
        dictationCoordinator.setEnabled(true)
        var keys: [DictationIntent: DictationActivationKey] = [:]
        if settings.dictationEnabled { keys[.dictation] = settings.dictationActivationKey }
        if settings.assistantEnabled { keys[.assistant] = settings.assistantActivationKey }
        triggerMonitor.setKeys(keys)
        triggerMonitor.setTiming(
            holdThreshold: Double(settings.dictationHoldThresholdMs) / 1_000,
            doubleTapInterval: Double(settings.dictationDoubleTapMs) / 1_000,
            maximumDuration: Double(min(settings.dictationMaxDictationMinutes, 5)) * 60
        )
        triggerMonitor.start()
    }

    func stopToggleDictation() { triggerMonitor.stopToggle() }

    /// The indicator's ✕: a request past its key (loading the model,
    /// transcribing, or asking the assistant), else a toggled session.
    func cancelToggleDictation() {
        if dictationCoordinator?.cancelPendingRequest() == true { return }
        triggerMonitor.cancelToggle()
    }

    /// What the assistant key does right now, resolved at each press so a
    /// change in Settings applies to the next request.
    private func assistantAvailability() -> AssistantAvailability {
        let account = VoiceAssistantAccount.shared
        guard let assistant = account.makeAssistant(settings: settings) else {
            return .needsAccount(account.setupMessage(settings: settings))
        }
        let modelName = account.modelName(settings: settings)
        return .ready(AssistantConfiguration(
            assistant: assistant,
            modelName: modelName,
            sources: SourceTextOptions(
                usesSelection: settings.assistantUsesSelection,
                usesCopiedText: settings.assistantUsesCopiedText,
                usesScreenText: settings.assistantUsesScreenText,
                characterLimit: settings.assistantSourceCharacterLimit
            ),
            copyOnly: settings.assistantResultMode == .copyOnly
        ))
    }

    func toggleDictation() {
        if !settings.dictationEnabled, settings.modelInstaller.state != .installed {
            dictationCoordinator?.showModelUnavailable()
            settingsFocus.request(.dictation)
            openSettingsWindow?()
            return
        }
        settings.dictationEnabled.toggle()
    }

    var updateMenuCommands: UpdateMenuCommands {
        UpdateMenuCommands(
            state: updateState,
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            installUpdate: { [weak self] in self?.installPreparedUpdate() }
        )
    }

    /// Looks only at GitHub's published latest release. A failed check leaves
    /// recording and every local feature usable. A newer release is downloaded
    /// and verified automatically; installing it still requires an explicit
    /// restart.
    func checkForUpdates() {
        guard !isDownloadingOrInstalling, preparedUpdate == nil else { return }
        updateTask?.cancel()
        updateState = .checking
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        updateTask = Task { [weak self] in
            do {
                let release = try await GitHubReleaseClient.fetchLatestRelease()
                guard !Task.isCancelled else { return }
                if ScribeReleaseVersion.isNewer(release.version, than: currentVersion) {
                    self?.download(release)
                } else {
                    self?.updateState = .upToDate
                }
            } catch is CancellationError {
                // A subsequent request owns the visible state.
            } catch {
                guard !Task.isCancelled else { return }
                self?.updateState = .failed(message: "Could not check for updates")
            }
        }
    }

    func cleanUpPendingUpdateOnTermination() {
        updateTask?.cancel()
        if updateState != .installing, let preparedUpdate {
            updater.discard(preparedUpdate)
        }
    }

    private var isDownloadingOrInstalling: Bool {
        switch updateState {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Starts as soon as a check finds a newer release; there is no manual
    /// download step.
    private func download(_ release: GitHubRelease) {
        guard !isDownloadingOrInstalling, preparedUpdate == nil else { return }
        updateState = .downloading(version: release.version)
        let application = Bundle.main.bundleURL
        updateTask = Task { [weak self, updater] in
            do {
                let prepared = try await updater.prepare(release: release, application: application)
                guard let self, !Task.isCancelled else {
                    updater.discard(prepared)
                    return
                }
                self.preparedUpdate = prepared
                self.updateState = .readyToInstall(version: release.version)
            } catch {
                self?.updateState = .failed(message: error.localizedDescription)
            }
        }
    }

    private func installPreparedUpdate() {
        guard let preparedUpdate, updateState != .installing else { return }
        updateState = .installing
        updateTask = Task { [weak self, updater] in
            do {
                try await updater.launchInstaller(preparedUpdate, processID: ProcessInfo.processInfo.processIdentifier)
                // AppDelegate drains and saves any active recording before exit.
                Self.requestTermination()
            } catch {
                updater.discard(preparedUpdate)
                self?.preparedUpdate = nil
                self?.updateState = .failed(message: error.localizedDescription)
            }
        }
    }

    private static func requestTermination() {
        // AppKit runs a modal event loop while it waits for the delegate's reply.
        // Enter it from the run loop so it can service the main queue, which
        // runs the capture drain and draft flush.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Applies whatever changed while the Settings window was open. Shortcut
    /// conflicts are shown in the menu; the menu commands are never affected.
    func settingsWindowDidClose() {
        syncTriggerMonitors()
        coordinator.setRecordingsFolder(settings.recordingsFolderURL)
        registerShortcuts()
    }

    /// Registers every global shortcut and reports conflicts in the menu.
    /// Meeting Notes is registered only where there are meeting notes.
    private func registerShortcuts() {
        coordinator.reportShortcutRegistration(
            hotkeys.register(
                start: settings.startShortcut,
                stop: settings.stopShortcut,
                pasteTimestamp: settings.pasteTimestampShortcut,
                meetingNotes: transcription == nil ? nil : settings.meetingNotesShortcut
            )
        )
    }

    /// Takes the global shortcuts down while a Settings field is listening for
    /// a new one, so pressing the current combination records it rather than
    /// starting a recording, and puts them back, with any change, afterwards.
    func setShortcutCaptureActive(_ isActive: Bool) {
        if isActive {
            hotkeys.unregisterAll()
        } else {
            registerShortcuts()
        }
    }

    /// Shows the first-run setup window: once per install, so the model
    /// download and Login Items are offered alongside the permission requests,
    /// and after that whenever a permission is missing. After a denial macOS
    /// stops prompting, so the window's job then is to hand over the System
    /// Settings route.
    func presentFirstRunPermissionsIfNeeded() {
        let recordingReady = permissions.currentStatus().isReadyToRecord
        let dictationReady = !settings.dictationEnabled || permissions.dictationAccess().isReady
        guard FirstRunSetup.shouldPresent(
            recordingReady: recordingReady,
            dictationReady: dictationReady,
            setupCompleted: settings.hasCompletedFirstRunSetup
        ) else { return }
        if !recordingReady {
            coordinator.submit(.requestPermissions)
        }

        if let firstRunWindow {
            firstRunWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ScribePermissionsView(model: menuModel, settings: settings, permissions: permissions) { [weak self] in
                self?.settings.markFirstRunSetupCompleted()
                self?.firstRunWindow?.close()
            }
        ))
        window.title = "Welcome to Scribe"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        firstRunWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Background processing

    /// Mirrors queue outcomes into the menu's separate background-processing
    /// section, and runs the transcription handoff when a job finishes.
    private func observeProcessingQueue() {
        guard let processingQueue else { return }
        queueEventTask = Task { [weak self] in
            let events = await processingQueue.events()
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: ProcessingQueue.Event) async {
        switch event {
        case .queued(let job):
            coordinator.noteBackgroundJob(id: job.id, title: "Waiting to process recording")
        case .started(let job):
            coordinator.noteBackgroundJob(id: job.id, title: "Processing recording")
            coordinator.reportBackgroundFailure(nil)
        case .completed(let job):
            coordinator.finishBackgroundJob(id: job.id)
            await handOffForTranscription(job)
            transcription?.recordingProcessingDidChange()
            retireRecoveryNotice(for: job.id)
        case .failed(let job, let message):
            coordinator.finishBackgroundJob(id: job.id)
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: "processing.failed",
                message: "Audio cleanup failed for one recording: \(message)",
                recoveryHint: "The original tracks were kept. Open the recordings folder to reprocess."
            ))
            transcription?.recordingProcessingDidChange()
            retireRecoveryNotice(for: job.id)
        }
    }

    /// Submits a `TranscriptionRequest` for verified `final.m4a` recorder output.
    ///
    /// A refusal is surfaced instead of being worked around: handing over a raw
    /// track when cleanup failed would look like a successful transcription of
    /// the meeting and would be wrong in a way nobody would notice.
    private func handOffForTranscription(_ job: ProcessingQueue.QueuedJob) async {
        guard settings.transcribeWhenFinalRecordingIsReady else { return }
        let draftID = await transcription?.draftIDForHandoff(sessionDirectory: job.sessionDirectory)
        if await publishFinishedRecording(sessionDirectory: job.sessionDirectory, draftID: draftID) == nil {
            // The request is durable now, so transcription can be told to pick it
            // up. If this call never happens — a crash, or a build with no
            // transcription module — the next launch consumes the outbox instead.
            transcription?.recordingWasPublished()
        }
    }

    /// Verifies a finished session and writes its request to the outbox.
    ///
    /// The request ID is derived from the session, so publishing twice (the
    /// processing event and launch reconciliation, say) is one request. Returns
    /// a failure message, or nil once the request is on file; refusals are
    /// also reported in the menu, since a meeting nobody transcribed looks the
    /// same as one that is still processing.
    @discardableResult
    private func publishFinishedRecording(sessionDirectory: URL, draftID: UUID?) async -> String? {
        do {
            let handoff = FinalRecordingHandoff(speakerCount: Self.transcriptionSpeakerCount(settings.transcriptionSpeakerCount), microphoneSpeakerPrior: settings.microphoneSpeakerPrior)
            let request = try handoff.request(forSessionAt: sessionDirectory, draftID: draftID)
            try await outbox.submit(request)
            return nil
        } catch let refusal as FinalRecordingHandoffRefusal {
            guard !refusal.isTransient else { return refusal.message }
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: refusal.code,
                message: refusal.message,
                recoveryHint: refusal.recoveryHint
            ))
            return refusal.message
        } catch {
            let message = "The final recording is ready but could not be handed to transcription: \(error.localizedDescription)"
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: "handoff.notSubmitted",
                message: message,
                recoveryHint: "Open the recordings folder; the recording itself is complete."
            ))
            return message
        }
    }

    /// Forwards capture facts to the meeting drafts. Session-ID based, so a
    /// resume (which re-reports recording) never opens a second draft.
    private func recordingLifecycleDidChange(_ event: RecordingLifecycleEvent) {
        guard let transcription else { return }
        switch event {
        case let .captureStarted(sessionID, startedAt, title, sessionDirectory):
            transcription.draftCaptureStarted(
                sessionID: sessionID,
                startedAt: startedAt,
                title: title,
                sessionName: sessionDirectory.lastPathComponent
            )
        case let .pauseChanged(sessionID, isPaused):
            transcription.draftPauseChanged(sessionID: sessionID, isPaused: isPaused)
        case let .captureStopped(sessionID, _, reason):
            transcription.draftCaptureStopped(sessionID: sessionID, reason: MeetingStopReason(journalReason: reason.journalReason))
        case let .captureFailed(sessionID, message):
            transcription.draftCaptureFailed(sessionID: sessionID, message: message)
        }
    }

    /// Saves pending meeting-draft edits before the app exits.
    func flushDraftsForTermination(then completion: @escaping @MainActor () -> Void) {
        guard let transcription else {
            // Never reply inside applicationShouldTerminate itself.
            Task { @MainActor in completion() }
            return
        }
        transcription.flushDraftsForTermination(then: completion)
    }

    private static func transcriptionSpeakerCount(_ preference: RecorderSpeakerCountPreference) -> TranscriptionSpeakerCount {
        switch preference {
        case .automatic: .automatic
        case .known(let count): .known(count)
        }
    }

    // MARK: - Launch recovery

    /// Requeues processing left behind by a previous launch and tells the person
    /// what was found. Repaired captures and requeued processing are reported
    /// together because from the outside they are one fact: an earlier meeting
    /// survived and is still being finished.
    private func adoptWorkFoundAtLaunch() {
        guard let processingQueue else { return }
        Task { [weak self] in
            guard let self else { return }
            let requeued = (try? await processingQueue.recoverSessions(in: self.settings.recordingsFolderURL)) ?? []
            self.adoptedSessionIDs.formUnion(requeued.map(\.id))
            self.refreshRecoveryNotice()
            await processingQueue.runPending()
        }
    }

    /// Called by `LiveRecordingCoordinator` once its own capture-repair scan has
    /// run, before any new stream can be created.
    func reportRepairedCaptures(_ recovered: [SessionStore.RecoveredSession]) {
        let ids = recovered.map(\.sessionID)
        repairedSessionIDs.formUnion(ids)
        adoptedSessionIDs.formUnion(ids)
        refreshRecoveryNotice()
    }

    /// The notice describes work still outstanding, so it clears itself as that
    /// work finishes rather than lingering until the next launch.
    private func retireRecoveryNotice(for sessionID: UUID) {
        guard adoptedSessionIDs.remove(sessionID) != nil else { return }
        repairedSessionIDs.remove(sessionID)
        refreshRecoveryNotice()
    }

    private func refreshRecoveryNotice() {
        guard !adoptedSessionIDs.isEmpty else {
            coordinator.setRecoveryNotice(nil)
            return
        }
        let subject = adoptedSessionIDs.count == 1 ? "1 recording" : "\(adoptedSessionIDs.count) recordings"
        coordinator.setRecoveryNotice(repairedSessionIDs.isEmpty
            ? "Resumed processing for \(subject) from a previous launch."
            : "Recovered \(subject) from an interrupted session; finishing them now.")
    }
}

// MARK: - Transcription

extension ScribeAppEnvironment {
    /// What the menu renders for transcription, or nil when the module could not
    /// be composed. The recorder rows above it are unaffected either way.
    var transcriptionMenuCommands: TranscriptionMenuCommands? {
        guard let transcription else { return nil }
        return TranscriptionMenuCommands(
            statusLines: [transcriptionStatus.lastImportSummary].compactMap { $0 } + transcriptionStatus.lines,
            failure: transcriptionStatus.failure,
            openTranscripts: { [weak self] in self?.openTranscriptWindow() },
            openSpeakers: transcription.speakersAreAvailable ? { [weak self] in self?.openSpeakersWindow() } : nil,
            transcribeFolder: { transcription.chooseFolderToTranscribe() },
            openTranscriptionsFolder: { NSWorkspace.shared.open(transcription.storeDirectoryURL) },
            openMeetingNotes: { [weak self] sessionID in self?.openMeetingNotes(sessionID: sessionID) }
        )
    }

    // MARK: - Meeting notes panel

    static let noRecordingHint = "Nothing is being recorded. Meeting Notes opens during a recording."

    /// The Meeting Notes shortcut: the notes of the recording in progress
    /// (recording or held), and nothing else (decision 13). With nothing
    /// recording it only says so.
    func openLiveMeetingNotes() {
        let state = coordinator.snapshot.state
        guard transcription != nil, state.isCapturing, let sessionID = state.activity?.sessionID else {
            showHint?(Self.noRecordingHint)
            return
        }
        openMeetingNotes(sessionID: sessionID)
    }

    /// Opens the floating notes panel on the draft of the recording with
    /// this session ID: the one the chip or the menu row was showing.
    func openMeetingNotes(sessionID: UUID) {
        guard let transcription else { return }
        Task { [weak self] in
            // A press in the first moment of a recording waits for its draft.
            guard let draftID = await transcription.draftID(forSession: sessionID) else {
                self?.showHint?("This recording has no notes yet. Try again in a moment.")
                return
            }
            self?.showMeetingNotes(draftID: draftID)
        }
    }

    private func showMeetingNotes(draftID: UUID) {
        guard let transcription else { return }
        // The same review model as the Transcripts window, so the panel and
        // the window edit one draft session.
        let model = transcription.makeOrRefreshReviewModel()
        let panel: MeetingNotesPanelController
        if let meetingNotesPanel, meetingNotesPanel.viewModel === model {
            panel = meetingNotesPanel
        } else {
            panel = MeetingNotesPanelController(viewModel: model)
            panel.openInTranscripts = { [weak self] draftID in self?.revealMeetingInTranscripts(draftID: draftID) }
            meetingNotesPanel = panel
        }
        panel.show(draftID: draftID)
    }

    /// "Open in Transcripts": the window, with the meeting's row selected.
    func revealMeetingInTranscripts(draftID: UUID) {
        openTranscriptWindow()
        transcription?.reviewModel?.selectedFileID = draftID.uuidString
    }

    /// Opens the review window, or brings the existing one forward.
    ///
    /// One window and one view model: an unsaved relabelling must not be
    /// stranded behind a second copy of the same transcript.
    func openTranscriptWindow() {
        guard let transcription else { return }
        let model = transcription.makeOrRefreshReviewModel()
        if let transcriptWindow {
            NSApp.activate(ignoringOtherApps: true)
            transcriptWindow.makeKeyAndOrderFront(nil)
            return
        }
        // The hosting controller must not publish a preferred content size:
        // with it, AppKit resizes the window to the SwiftUI ideal height, so a
        // long transcript opens near full screen and a resize the user made is
        // undone the next time a transcript is selected.
        let host = NSHostingController(rootView: TranscriptWindow(viewModel: model))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Transcripts"
        // SwiftUI lays its toolbar out as if the content runs under the title
        // bar and reserves a toolbar-height top pocket for it. Without a full-size
        // content view AppKit has already placed the content below the bar, so on
        // the macOS 26 SDK that pocket lands on the transcript header instead.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        // A remembered frame wins; the fixed default applies only the first time.
        window.setContentSize(NSSize(width: 1_040, height: 680))
        window.center()
        window.setFrameAutosaveName("ScribeTranscriptWindow")
        transcriptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens Settings and marks the vocabulary section, so a person who pressed
    /// the transcript window's button lands on the thing they asked for rather
    /// than at the top of a window of eight sections.
    func openVocabularySettings() {
        settingsFocus.request(.vocabulary)
        openSettingsWindow?()
    }

    func openSpeakersWindow() {
        guard let model = transcription?.makeOrRefreshSpeakerLibraryModel() else { return }
        if let speakersWindow {
            speakersWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SpeakersView(viewModel: model)))
        window.title = "Speakers"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        speakersWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
