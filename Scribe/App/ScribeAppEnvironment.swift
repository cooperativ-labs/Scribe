import AppKit
import Capture
import Platform
import Processing
import ScribeAppCore
import ScribeUI
import Speakers
import Storage
import SwiftUI
import Transcription

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
    @Published private(set) var detectedMeeting: DetectedMeeting?
    private let processingQueue: ProcessingQueue?
    private let outbox: TranscriptionRequestOutbox
    private let handoff = FinalRecordingHandoff()
    /// Absent only when the transcript store cannot be opened at all; the
    /// recorder is unaffected either way.
    let transcription: TranscriptionHostService?
    /// Mirrors the transcription service's status into the menu.
    @Published private(set) var transcriptionStatus = TranscriptionHostService.Status()
    @Published private(set) var updateState: UpdateMenuState = .idle
    private var transcriptWindow: NSWindow?
    private var speakersWindow: NSWindow?

    private let hotkeys: HotkeyService
    private var firstRunWindow: NSWindow?
    private var selectionObservation: RecorderObservationToken?
    private var queueEventTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var availableRelease: GitHubRelease?
    private let updater = ApplicationUpdater()
    private var preparedUpdate: ApplicationUpdater.PreparedUpdate?
    /// Sessions this launch adopted rather than started, so the recovery notice
    /// can be retired once the last one is finished with.
    private var adoptedSessionIDs: Set<UUID> = []
    /// The subset whose raw capture had to be repaired, which is a stronger fact
    /// than merely finding processing left over, and is worded differently.
    private var repairedSessionIDs: Set<UUID> = []

    init() {
        let settings = ScribeSettings()
        let permissions = PermissionService()
        self.settings = settings
        self.permissions = permissions
        processingQueue = try? ProcessingQueue(configuration: .inRecordingsDirectory(settings.recordingsFolderURL))
        outbox = .inRecordingsDirectory(settings.recordingsFolderURL)

        let coordinator = LiveRecordingCoordinator(
            snapshot: RecorderSnapshot(
                permissions: permissions.currentStatus(),
                selectedApplicationID: settings.rememberedApplicationBundleIdentifier,
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
            }
        )
        self.coordinator = coordinator
        menuModel = RecorderMenuModel(coordinator: coordinator)
        meetingChipModel = MeetingChipModel(
            coordinator: coordinator,
            shouldStopWhenMeetingEnds: {
                settings.meetingDetectionEnabled && settings.stopRecordingWhenMeetingEnds
            }
        )
        hotkeys = HotkeyService(coordinator: coordinator)
        meetingDetector = MeetingDetector(settings: settings)

        transcription = try? TranscriptionHostService(settings: settings, scheduler: processingQueue)

        coordinator.terminationHandler = { NSApplication.shared.terminate(nil) }
        coordinator.recoveryReporter = { [weak self] recovered in
            self?.reportRepairedCaptures(recovered)
        }
        coordinator.reportShortcutRegistration(
            hotkeys.register(start: settings.startShortcut, stop: settings.stopShortcut)
        )
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
        }

        // Detection only reports. The chip turns that report into an offer and,
        // when the person opted in, finishes the recording it started after the
        // detector's end-of-call grace period has elapsed.
        meetingDetector.onChange = { [weak self] meeting in
            self?.detectedMeeting = meeting
            self?.meetingChipModel.meetingWasDetected(meeting)
        }
        meetingDetector.start()
    }

    deinit {
        queueEventTask?.cancel()
        updateTask?.cancel()
    }

    var updateMenuCommands: UpdateMenuCommands {
        UpdateMenuCommands(
            state: updateState,
            checkForUpdates: { [weak self] in self?.checkForUpdates() },
            downloadUpdate: { [weak self] in self?.downloadAvailableUpdate() },
            installUpdate: { [weak self] in self?.installPreparedUpdate() }
        )
    }

    /// Looks only at GitHub's published latest release. A failed check leaves
    /// recording and every local feature usable, and a successful check never
    /// downloads anything until the person explicitly chooses to do so.
    func checkForUpdates() {
        guard updateState != .downloading, updateState != .installing, preparedUpdate == nil else { return }
        updateTask?.cancel()
        updateState = .checking
        availableRelease = nil
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        updateTask = Task { [weak self] in
            do {
                let release = try await GitHubReleaseClient.fetchLatestRelease()
                guard !Task.isCancelled else { return }
                if ScribeReleaseVersion.isNewer(release.version, than: currentVersion) {
                    self?.availableRelease = release
                    self?.updateState = .updateAvailable(version: release.version)
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

    private func downloadAvailableUpdate() {
        guard let release = availableRelease, updateState != .downloading,
              updateState != .installing, preparedUpdate == nil else { return }
        updateState = .downloading
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
                NSApplication.shared.terminate(nil)
            } catch {
                updater.discard(preparedUpdate)
                self?.preparedUpdate = nil
                self?.updateState = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Applies whatever changed while the Settings window was open. Shortcut
    /// conflicts are shown in the menu; the menu commands are never affected.
    func settingsWindowDidClose() {
        coordinator.setRecordingsFolder(settings.recordingsFolderURL)
        coordinator.reportShortcutRegistration(
            hotkeys.register(start: settings.startShortcut, stop: settings.stopShortcut)
        )
    }

    /// Shows the first-run permission window when either permission is missing.
    /// After a denial macOS stops prompting, so the window's real job is to hand
    /// over the System Settings route.
    func presentFirstRunPermissionsIfNeeded() {
        guard !permissions.currentStatus().isReadyToRecord else { return }
        coordinator.submit(.requestPermissions)

        if let firstRunWindow {
            firstRunWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ScribePermissionsView(model: menuModel) { [weak self] in
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
            retireRecoveryNotice(for: job.id)
        case .failed(let job, let message):
            coordinator.finishBackgroundJob(id: job.id)
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: "processing.failed",
                message: "Audio cleanup failed for one recording: \(message)",
                recoveryHint: "The original tracks were kept. Open the recordings folder to reprocess."
            ))
            retireRecoveryNotice(for: job.id)
        }
    }

    /// Submits a `TranscriptionRequest` for `final.flac`, and only for a
    /// `final.flac` that has been published and verified.
    ///
    /// A refusal is surfaced instead of being worked around: handing over a raw
    /// track when cleanup failed would look like a successful transcription of
    /// the meeting and would be wrong in a way nobody would notice.
    private func handOffForTranscription(_ job: ProcessingQueue.QueuedJob) async {
        guard settings.transcribeWhenFinalRecordingIsReady else { return }
        do {
            let request = try handoff.request(forSessionAt: job.sessionDirectory)
            try await outbox.submit(request)
            // The request is durable now, so transcription can be told to pick it
            // up. If this call never happens — a crash, or a build with no
            // transcription module — the next launch consumes the outbox instead.
            transcription?.recordingWasPublished()
        } catch let refusal as FinalRecordingHandoffRefusal {
            guard !refusal.isTransient else { return }
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: refusal.code,
                message: refusal.message,
                recoveryHint: refusal.recoveryHint
            ))
        } catch {
            coordinator.reportBackgroundFailure(RecorderFailure(
                code: "handoff.notSubmitted",
                message: "The final recording is ready but could not be handed to transcription: \(error.localizedDescription)",
                recoveryHint: "Open the recordings folder; the recording itself is complete."
            ))
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
            transcribeFolder: { transcription.chooseFolderToTranscribe() }
        )
    }

    /// Opens the review window, or brings the existing one forward.
    ///
    /// One window and one view model: an unsaved relabelling must not be
    /// stranded behind a second copy of the same transcript.
    func openTranscriptWindow() {
        guard let transcription else { return }
        let model = transcription.makeOrRefreshReviewModel()
        if let transcriptWindow {
            transcriptWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: TranscriptWindow(viewModel: model)))
        window.title = "Transcripts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_040, height: 680))
        window.isReleasedWhenClosed = false
        window.center()
        transcriptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
