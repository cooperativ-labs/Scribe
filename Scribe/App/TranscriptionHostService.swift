import AppKit
import Foundation
import Platform
import Processing
import ScribeAppCore
import Speakers
import Transcription

/// The host's side of the transcription module contract.
///
/// The recorder never calls transcription directly and transcription never
/// calls the recorder: the two meet at the durable outbox and at the shared
/// `ProcessingScheduler`. This object is the only place that knows about both,
/// which is what keeps capture independent of whether transcription is running,
/// installed, or even reachable.
///
/// Everything it owns is durable. Jobs live in the transcript store, handoff
/// requests live in the outbox, and both survive a quit, so nothing here has to
/// be finished before the application may exit.
@MainActor
final class TranscriptionHostService {
    /// What the menu shows for transcription, kept separate from the recorder's
    /// own status because a queued transcription says nothing about capture.
    struct Status: Equatable {
        /// Queue and progress, replaced as jobs move.
        var lines: [String] = []
        /// The outcome of the last folder import, which survives the queue lines
        /// that follow it: "3 files could not be read" is the answer to what the
        /// person just did, and a queue count does not replace it.
        var lastImportSummary: String?
        var failure: String?
    }

    private(set) var status = Status()
    /// Non-nil once a transcript window has been opened; a single window and a
    /// single view model, so an edit made in it is the one that is saved.
    private(set) var reviewModel: TranscriptViewModel?
    private(set) var speakerLibraryModel: SpeakerLibraryViewModel?

    let storeDirectoryURL: URL

    private let coordinator: TranscriptionCoordinator
    private let store: TranscriptStore
    private let outbox: TranscriptionRequestOutbox
    private let settings: ScribeSettings
    private let importer: FolderImportService?
    private let speakerStore: SpeakerProfileStore?
    private let modelProfileID: String
    /// Recording priority is enforced through this contract, so its absence
    /// disables running rather than silently removing the priority.
    private let hasScheduler: Bool
    /// Reported once at construction and shown in the window rather than thrown:
    /// a missing helper must not stop a person from reading transcripts that
    /// were produced before it went missing.
    private let workerUnavailableReason: String?

    private var eventTask: Task<Void, Never>?
    private var statusDidChange: (@MainActor (Status) -> Void)?

    init(
        settings: ScribeSettings,
        scheduler: (any ProcessingScheduler)?,
        storeDirectoryURL: URL = TranscriptStore.defaultStoreDirectoryURL(),
        modelProfileID: String = "parakeet-v3"
    ) throws {
        self.settings = settings
        self.storeDirectoryURL = storeDirectoryURL
        self.modelProfileID = modelProfileID
        hasScheduler = scheduler != nil
        store = TranscriptStore(storeDirectoryURL: storeDirectoryURL)
        outbox = .inRecordingsDirectory(settings.recordingsFolderURL)
        speakerStore = try? SpeakerProfileStore.openApplicationSupportLibrary()

        let assembly = TranscriptAssemblyStageRunner()
        let stageRunner: any TranscriptionStageRunning
        do {
            stageRunner = WorkerStageRunner(
                configuration: .init(installation: try WorkerLocator.locate()),
                hostStageRunner: assembly
            )
            workerUnavailableReason = nil
        } catch {
            // The host stages still run, so a job reaches the helper's first
            // stage and fails there with the locator's own reason attached.
            stageRunner = UnavailableWorkerStageRunner(reason: error.localizedDescription, hostStageRunner: assembly)
            workerUnavailableReason = error.localizedDescription
        }

        coordinator = try TranscriptionCoordinator(
            configuration: .init(transcriptStoreURL: storeDirectoryURL),
            scheduler: scheduler,
            stageRunner: stageRunner
        )
        importer = (try? MediaToolLocator.ffprobe()).map { FolderImportService(prober: MediaProber(ffprobeURL: $0)) }
    }

    deinit { eventTask?.cancel() }

    /// Starts consuming durable work: jobs interrupted by a previous launch, and
    /// handoff requests the recorder wrote while transcription was not running.
    func start(statusDidChange: @escaping @MainActor (Status) -> Void) {
        self.statusDidChange = statusDidChange
        if let workerUnavailableReason {
            status.failure = "Transcription is unavailable: \(workerUnavailableReason)"
            publishStatus()
        }
        observeJobEvents()
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.coordinator.recoverPendingJobs()
            await self.consumeHandoffRequests()
            await self.runPending()
        }
    }

    // MARK: - Producer handoff

    /// Claims every request the recorder has published and queues it.
    ///
    /// A request is claimed only after its job is durably recorded, so a crash
    /// between the two leaves the request in the outbox to be queued again
    /// rather than losing the meeting. Requeueing the same source is harmless:
    /// the fingerprint identifies it as a repeat import.
    func consumeHandoffRequests() async {
        do {
            let outcome = try await TranscriptionHandoffConsumer(source: outbox).drain(into: coordinator)
            guard !outcome.isEmpty else { return }
            if let first = outcome.failures.first {
                report(failure: "A finished recording could not be queued for transcription: \(first.message)")
            }
            await refreshReview()
        } catch {
            report(failure: "The transcription handoff could not be read: \(error.localizedDescription)")
        }
    }

    /// Called when a recorder session finishes publishing its final file.
    ///
    /// Draining and running happen on their own task. The caller is the
    /// recorder's queue-event loop, and it must stay free to report the next
    /// recording rather than waiting out a transcription run.
    func recordingWasPublished() {
        guard settings.transcribeWhenFinalRecordingIsReady else { return }
        Task { [weak self] in
            await self?.consumeHandoffRequests()
            await self?.runPending()
        }
    }

    // MARK: - Folder import

    /// Runs the shipping folder importer over a chosen folder and queues the
    /// files it preselected. Files it refused keep their per-file reason and are
    /// reported without stopping the rest of the folder.
    @discardableResult
    func importFolder(at rootURL: URL, includeSubfolders: Bool = false) async -> FolderImportResult? {
        guard let importer else {
            report(failure: "The bundled media prober is unavailable, so folders cannot be imported.")
            return nil
        }
        let configuration = ImportConfiguration(modelProfileID: modelProfileID)
        let options = FolderImportOptions(
            configuration: configuration,
            includeSubfolders: includeSubfolders,
            transcriptStoreDirectory: storeDirectoryURL
        )
        let result: FolderImportResult
        do {
            result = try importer.scan(rootURL, options: options)
        } catch {
            report(failure: "That folder could not be read: \(error.localizedDescription)")
            return nil
        }

        // A recognized recorder session names itself; anything else is an
        // ordinary local file and carries no producer, which is the point of the
        // module accepting any source.
        let sessionIDsByDirectory = Dictionary(
            result.recorderSessions.compactMap { session in
                session.sessionID.map { (session.directoryURL.standardizedFileURL, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        var queued = 0
        for file in result.preselectedFiles where file.isImportable {
            let sessionID = file.recorderSessionDirectoryURL
                .flatMap { sessionIDsByDirectory[$0.standardizedFileURL] }
            do {
                _ = try await coordinator.enqueue(TranscriptionRequest(
                    sourceURL: file.url,
                    modelProfileID: modelProfileID,
                    provenance: sessionID.map { TranscriptionProvenance(producerID: "scribe.recorder", sessionID: $0) }
                ))
                queued += 1
            } catch {
                report(failure: "\(file.relativePath) could not be queued: \(error.localizedDescription)")
            }
        }

        let refused = result.failedFiles.count
        status.lastImportSummary = "Queued \(queued) file\(queued == 1 ? "" : "s") from \(rootURL.lastPathComponent)"
            + (refused == 0 ? "" : "; \(refused) could not be read")
        publishStatus()
        await refreshReview()
        // The import is finished once the files are queued; running them is the
        // coordinator's business and the scheduler's to time.
        Task { [weak self] in await self?.runPending() }
        return result
    }

    /// The folder chooser the menu opens. Security-scoped access is held for the
    /// scan and the snapshot copies, which is all the module needs the original
    /// folder for.
    func chooseFolderToTranscribe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Transcribe"
        panel.message = "Choose a folder of recordings to transcribe."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            await self?.importFolder(at: url)
        }
    }

    // MARK: - Review

    /// Builds the window's view model on first open and refreshes it afterwards.
    func makeOrRefreshReviewModel() -> TranscriptViewModel {
        if let reviewModel {
            reviewModel.reload(files: reviewFiles())
            return reviewModel
        }
        let model = TranscriptViewModel(
            files: reviewFiles(),
            playback: AVFoundationTranscriptPlayback(),
            directory: speakerDirectory(),
            revisionStore: TranscriptStoreRevisionWriter(store: store)
        )
        reviewModel = model
        return model
    }

    /// The Speakers view needs the local library; without it the menu hides the
    /// entry rather than opening a window that can show nothing.
    var speakersAreAvailable: Bool { speakerStore != nil }

    func makeOrRefreshSpeakerLibraryModel() -> SpeakerLibraryViewModel? {
        guard let speakerStore else { return nil }
        if let speakerLibraryModel { return speakerLibraryModel }
        let model = SpeakerLibraryViewModel(store: speakerStore)
        speakerLibraryModel = model
        return model
    }

    private func reviewFiles() -> [TranscriptReviewFile] {
        store.latestRunPerSource().map(TranscriptReviewFile.init)
    }

    private func refreshReview() async {
        reviewModel?.reload(files: reviewFiles())
    }

    private func speakerDirectory() -> (any TranscriptSpeakerDirectory)? {
        guard let speakerStore else { return nil }
        return SpeakerLibraryTranscriptDirectory(store: speakerStore, extractor: UnavailableEmbeddingExtractor())
    }

    // MARK: - Running

    /// Asks the coordinator to drain its queue. The scheduler, not this call,
    /// decides whether anything actually starts: a job offered while capture is
    /// active is deferred and stays queued.
    ///
    /// With no scheduler there is nothing to enforce recording priority, so
    /// nothing runs. Jobs stay queued and durable, and review and export keep
    /// working on transcripts that already exist; competing with a recording for
    /// the machine would be the worse failure.
    func runPending() async {
        guard hasScheduler else {
            report(failure: "Transcription is paused: the processing scheduler is unavailable, and recording must keep priority.")
            return
        }
        await coordinator.runPending()
    }

    private func observeJobEvents() {
        eventTask = Task { [weak self] in
            guard let self else { return }
            let events = await coordinator.events()
            for await event in events {
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TranscriptionCoordinator.Event) async {
        switch event {
        case .queued:
            await updateQueueStatus()
        case let .stageStarted(job):
            status.lines = ["Transcribing \(job.request.sourceURL.lastPathComponent) — \(job.state.rawValue)"]
            publishStatus()
        case .checkpointCompleted:
            break
        case .completed:
            await updateQueueStatus()
            await refreshReview()
        case .cancelled:
            await updateQueueStatus()
            await refreshReview()
        case let .failed(job, diagnostic):
            report(failure: "Transcription of \(job.request.sourceURL.lastPathComponent) failed: \(diagnostic.message)")
            await refreshReview()
        case let .suspended(job):
            // Recording has priority; saying so is more useful than a job that
            // silently stops making progress.
            status.lines = ["Transcription of \(job.request.sourceURL.lastPathComponent) paused while recording"]
            publishStatus()
        }
    }

    private func updateQueueStatus() async {
        let pending = await coordinator.pendingJobs().count
        status.lines = pending == 0 ? [] : ["\(pending) recording\(pending == 1 ? "" : "s") waiting to be transcribed"]
        publishStatus()
    }

    private func report(failure: String) {
        status.failure = failure
        publishStatus()
    }

    private func publishStatus() {
        statusDidChange?(status)
    }
}

/// Stands in for the helper when it cannot be found, so the coordinator still
/// exists and a job fails with the locator's reason rather than at launch.
private struct UnavailableWorkerStageRunner: TranscriptionStageRunning {
    let reason: String
    let hostStageRunner: any TranscriptionStageRunning

    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput {
        switch stage {
        case .reconcilingTimings, .assembling:
            return try await hostStageRunner.run(stage: stage, job: job)
        default:
            throw TranscriptionHostError.workerUnavailable(reason)
        }
    }
}

/// Enrolling a voice needs an embedding from the pinned model, which the helper
/// only produces as part of a full run today. Naming people still works; this
/// refuses clearly instead of writing a signature from something else.
private struct UnavailableEmbeddingExtractor: SpeakerEmbeddingExtracting {
    func extract(_ request: SpeakerEmbeddingExtractionRequest) async throws -> [ExtractedSpeakerEmbedding] {
        throw TranscriptionHostError.embeddingUnavailable
    }
}

enum TranscriptionHostError: LocalizedError {
    case workerUnavailable(String)
    case embeddingUnavailable

    var errorDescription: String? {
        switch self {
        case let .workerUnavailable(reason):
            "The transcription helper is not available: \(reason)"
        case .embeddingUnavailable:
            "Remembering a voice needs the transcription helper's embedding stage, which this build does not expose yet. Names assigned by hand still work."
        }
    }
}
