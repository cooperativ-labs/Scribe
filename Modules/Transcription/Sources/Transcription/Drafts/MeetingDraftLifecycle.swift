import Foundation
import os
import Platform
import ScribeAppCore

/// Drives meeting drafts through capture, handoff and transcription, and keeps
/// a main-actor mirror of the store for review.
///
/// Capture facts arrive from the app's composition root (start, pause, stop,
/// commit failure), job facts from the coordinator and the transcript store.
/// The event stream only makes things happen sooner: `reconcile` derives every
/// transition from durable records, so a missed event, a crash or a relaunch
/// lands in the same state.
@MainActor
public final class MeetingDraftLifecycle: MeetingDraftEditing {
    public enum LifecycleError: LocalizedError, Equatable {
        /// The title was changed elsewhere after the caller read it.
        case titleConflict
        case unknownDraft

        public var errorDescription: String? {
            switch self {
            case .titleConflict: "The name was changed elsewhere. Try again."
            case .unknownDraft: "This meeting draft no longer exists."
            }
        }
    }

    public let store: MeetingDraftStore
    private let transcriptStore: TranscriptStore?
    private let preferences: TranscriptAgentPreferences?

    public private(set) var drafts: [UUID: MeetingDraft] = [:]
    private var storeSaveStates: [UUID: MeetingDraftSaveState] = [:]
    public private(set) var liveCapture: LiveCaptureState?

    /// Whether each draft's latest edit is on disk: the draft record's own
    /// state, else a failed write of its meeting notes.
    public var saveStates: [UUID: MeetingDraftSaveState] {
        var states = storeSaveStates
        for (id, message) in notesErrors where states[id]?.isSaved != false {
            states[id] = .notSaved(message: message)
        }
        return states
    }

    /// Called after any change review should show.
    public var didChange: (@MainActor () -> Void)?
    /// Builds a row summary; the host supplies one that knows the session,
    /// outbox and settings state.
    public var summarize: (@MainActor (MeetingDraft, MeetingDraftSaveState) -> MeetingDraftSummary)?
    /// Publishes a finished recording to transcription. Returns a failure
    /// message, or nil when the request is on file.
    public var publishHandoff: (@MainActor (_ sessionDirectory: URL, _ draftID: UUID) async -> String?)?
    /// Where a session's files are, for "Transcribe Now".
    public var sessionDirectory: (@MainActor (_ sessionID: UUID) -> URL?)?
    /// The recording time a note written now gets for a session: the capture
    /// clock less the Paste Timestamp offset, nil unless audio is being
    /// captured. The host supplies it from the recorder; without one the
    /// live capture's own start time is used, with no offset.
    public var captureClock: (@MainActor (_ sessionID: UUID) -> Int?)?
    /// The quiet period before a finished meeting's notes are written.
    public var notesDebounce: Duration = MeetingDraftStore.defaultDebounce

    /// Notes of attached drafts as their meeting's sidecar holds them, read
    /// on first use and kept in step with every edit made here.
    private var attachedNotes: [UUID: [MeetingNote]] = [:]
    /// Attached drafts whose notes changed since the sidecar was written.
    private var dirtySidecars: Set<UUID> = []
    private var sidecarWrites: [UUID: Task<Void, Never>] = [:]
    /// Why a draft's notes could not be read or written, while they cannot.
    private var notesErrors: [UUID: String] = [:]
    /// Notes edits not yet in the draft store. While any is outstanding the
    /// mirror keeps the newest local notes, so a slower store notification
    /// never puts older text back under the editor.
    private var pendingDraftNotes: [UUID: Int] = [:]
    /// Handoff edits not yet in the draft store; the mirror keeps the newest
    /// local settings meanwhile, as it does for notes.
    private var pendingHandoffs: [UUID: Int] = [:]
    /// Serialises draft writes made from here (notes and handoff settings),
    /// so they reach the store in the order they were made.
    private var notesChain: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.scribe.app", category: "MeetingNotes")

    private var deletedIDs: Set<UUID> = []
    private var publishAttempts: Set<UUID> = []
    private var observation: Task<Void, Never>?

    public init(
        store: MeetingDraftStore,
        transcriptStore: TranscriptStore? = nil,
        preferences: TranscriptAgentPreferences? = nil
    ) async {
        self.store = store
        self.transcriptStore = transcriptStore
        self.preferences = preferences
        for draft in await store.all() {
            drafts[draft.id] = draft
            storeSaveStates[draft.id] = await store.saveState(id: draft.id)
        }
        let changes = await store.changes()
        observation = Task { [weak self] in
            for await change in changes {
                self?.apply(change)
            }
        }
    }

    deinit { observation?.cancel() }

    public var allDrafts: [MeetingDraft] {
        drafts.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func draftID(forSession sessionID: UUID) -> UUID? {
        drafts.values.first { $0.recorderSessionID == sessionID }?.id
    }

    // MARK: - Capture

    /// Capture is active for a session: open its draft, once. Resume and
    /// repeated start events find the same draft.
    @discardableResult
    public func captureStarted(sessionID: UUID, startedAt: Date, title: String?, sessionName: String) async -> MeetingDraft {
        liveCapture = LiveCaptureState(sessionID: sessionID, startedAt: startedAt)
        let handoff = preferences.map(MeetingHandoffSettings.init(seededFrom:)) ?? MeetingHandoffSettings()
        let defaultTitle = Self.nonEmpty(title) ?? sessionName
        let (draft, _) = await store.open(sessionID: sessionID, defaultTitle: defaultTitle, handoff: handoff, now: startedAt)
        await refresh(draft.id)
        return draft
    }

    public func capturePaused(_ isPaused: Bool, sessionID: UUID) {
        guard liveCapture?.sessionID == sessionID, liveCapture?.isPaused != isPaused else { return }
        liveCapture?.isPaused = isPaused
        didChange?()
    }

    /// Raw capture is committed. The draft waits for transcription, with the
    /// reason the recording ended.
    public func captureStopped(sessionID: UUID, reason: MeetingStopReason) async {
        // The session stays live until its phase has moved on, so a
        // reconciliation running meanwhile cannot mistake it for an
        // interrupted recording and overwrite the real stop reason.
        defer { endLiveCapture(sessionID) }
        guard let id = draftID(forSession: sessionID) else { return }
        await mutate(id, flush: true) { draft in
            if case .recording = draft.phase { draft.phase = .awaitingTranscription(reason) }
            if draft.stopReason == nil { draft.stopReason = reason }
        }
    }

    /// Finishing the recording failed after capture had started. The draft is
    /// kept with the reason so the row can say what happened.
    public func captureFailed(sessionID: UUID, message: String) async {
        defer { endLiveCapture(sessionID) }
        guard let id = draftID(forSession: sessionID) else { return }
        await mutate(id, flush: true) { draft in
            if case .recording = draft.phase { draft.phase = .awaitingTranscription(.streamFailure) }
            if draft.stopReason == nil { draft.stopReason = .streamFailure }
            draft.captureFailure = message
        }
    }

    private func endLiveCapture(_ sessionID: UUID) {
        guard liveCapture?.sessionID == sessionID else { return }
        liveCapture = nil
        didChange?()
    }

    /// Writes the draft now; used at handoff.
    public func flush(draftID: UUID) async {
        await store.flush(id: draftID)
        await refresh(draftID)
    }

    /// Writes every pending edit; used at normal termination.
    public func flushAll() async {
        await notesChain?.value
        for id in dirtySidecars { writeSidecar(draftID: id) }
        await store.flushAll()
    }

    // MARK: - Jobs

    /// The coordinator queued a run for a draft.
    public func jobQueued(_ job: TranscriptionJob) async {
        guard let id = job.draftID, drafts[id] != nil, job.retryOfRunID == nil else { return }
        await mutate(id) { draft in
            guard draft.phase.isPlaceholder else { return }
            draft.phase = .queued(runID: job.runID)
        }
    }

    // MARK: - Reconciliation

    /// Brings every draft in line with the durable records and returns the
    /// actions it took. Handoffs are published through `publishHandoff`.
    @discardableResult
    public func reconcile(
        sessions: [UUID: RecorderSessionEvidence],
        pendingRequests: [TranscriptionRequest],
        runs: [StoredTranscriptRun],
        autoTranscribe: Bool,
        isLaunch: Bool
    ) async -> [MeetingDraftReconciliationAction] {
        // The store, not the mirror: a change still on its way to the main
        // actor (a notes write that raced an attachment) must be seen.
        let input = MeetingDraftReconciliationInput(
            drafts: await store.all().filter { !deletedIDs.contains($0.id) },
            liveSessionID: liveCapture?.sessionID,
            sessions: sessions,
            pendingRequests: pendingRequests,
            runs: runs,
            autoTranscribe: autoTranscribe,
            isLaunch: isLaunch
        )
        let actions = MeetingDraftReconciler.actions(for: input)
        for action in actions {
            await perform(action, runs: runs)
        }
        if !actions.isEmpty { didChange?() }
        return actions
    }

    private func perform(_ action: MeetingDraftReconciliationAction, runs: [StoredTranscriptRun]) async {
        switch action {
        case .markInterrupted(let id):
            await mutate(id, flush: true) { draft in
                guard case .recording = draft.phase else { return }
                draft.phase = .awaitingTranscription(.interrupted)
                if draft.stopReason == nil { draft.stopReason = .interrupted }
                draft.recovered = true
            }
        case let .publishHandoff(id, sessionDirectory):
            // Once per draft per launch: a refused handoff (a checksum
            // mismatch, say) is reported, not retried on every state change.
            guard publishAttempts.insert(id).inserted else { return }
            await store.flush(id: id)
            _ = await publishHandoff?(sessionDirectory, id)
        case let .bindQueued(id, runID, recovered):
            await mutate(id, flush: true) { draft in
                draft.phase = .queued(runID: runID)
                if recovered { draft.recovered = true }
            }
        case let .attach(id, runID, meetingKey, recovered):
            // Title first, then notes, then the phase: a crash between any two
            // re-runs the attach, and renaming to the same title or writing
            // the same notes again changes nothing.
            if let draft = drafts[id], let title = draft.title,
               let run = runs.first(where: { $0.job.runID == runID }) {
                applyTitle(title, to: run)
            }
            await attach(id, meetingKey: meetingKey, runID: runID, recovered: recovered)
        case let .applyTitle(_, runID, title):
            if let run = runs.first(where: { $0.job.runID == runID }) { applyTitle(title, to: run) }
        case let .orphan(id, reason):
            await mutate(id, flush: true) { draft in
                draft.phase = .orphaned(reason)
            }
        case .restore(let id):
            await mutate(id, flush: true) { draft in
                if case .orphaned = draft.phase { draft.phase = .awaitingTranscription(.interrupted) }
            }
        }
    }

    /// Renames the run's saved transcript to the draft's title, as a review
    /// revision. Identical titles write nothing.
    private func applyTitle(_ title: String?, to run: StoredTranscriptRun) {
        guard let transcriptStore,
              let transcript = transcriptStore.transcript(forRunAt: run.runDirectoryURL),
              transcript.title != title,
              let renamed = try? TranscriptSegmentEditor.renaming(to: title, in: transcript) else { return }
        _ = try? transcriptStore.save(renamed, forRunAt: run.runDirectoryURL)
    }

    // MARK: - Editing

    public func setTitle(draftID: UUID, title: String?, basedOnRevision: Int, previousTitle: String?) async throws -> MeetingDraftSummary? {
        let title = Self.nonEmpty(title)
        do {
            try await store.update(id: draftID, expectedRevision: basedOnRevision) { $0.title = title }
        } catch MeetingDraftStore.StoreError.staleRevision {
            // The draft moved on (a phase change, say). Only a title someone
            // else changed since the caller read it is a conflict.
            guard let current = await store.draft(id: draftID) else { throw LifecycleError.unknownDraft }
            guard current.title == previousTitle else { throw LifecycleError.titleConflict }
            try await store.update(id: draftID) { $0.title = title }
        } catch MeetingDraftStore.StoreError.unknownDraft {
            throw LifecycleError.unknownDraft
        }
        await refresh(draftID)
        didChange?()
        return summary(for: draftID)
    }

    public func retrySave(draftID: UUID) async -> MeetingDraftSummary? {
        await store.retrySave(id: draftID)
        if dirtySidecars.contains(draftID) { writeSidecar(draftID: draftID) }
        await refresh(draftID)
        didChange?()
        return summary(for: draftID)
    }

    public func deleteDraft(draftID: UUID) async throws {
        await notesChain?.value
        try await store.delete(id: draftID)
        deletedIDs.insert(draftID)
        drafts[draftID] = nil
        storeSaveStates[draftID] = nil
        forgetNotes(draftID)
        didChange?()
    }

    public func transcribeNow(draftID: UUID) async -> String? {
        guard let draft = drafts[draftID] else { return LifecycleError.unknownDraft.errorDescription }
        guard let directory = sessionDirectory?(draft.recorderSessionID) else {
            return "The recording for this meeting could not be found."
        }
        await store.flush(id: draftID)
        return await publishHandoff?(directory, draftID) ?? "Transcription is not available right now."
    }

    public func summary(for draftID: UUID) -> MeetingDraftSummary? {
        guard let draft = drafts[draftID] else { return nil }
        let saveState = saveStates[draftID] ?? .saved
        return summarize?(draft, saveState) ?? MeetingDraftReviewMerger.summary(
            for: draft, saveState: saveState, run: nil,
            environment: .init(live: liveCapture, noteCounts: [draftID: noteCount(for: draftID)])
        )
    }

    // MARK: - Notes

    /// The notes a draft's row shows. Before transcription they are in the
    /// draft record; once its run has finished they are in the meeting's
    /// `meeting-notes.json`, the single copy every later run shows.
    public func notes(draftID: UUID) -> MeetingNotesContent {
        guard let draft = drafts[draftID] else {
            return .unavailable(LifecycleError.unknownDraft.errorDescription ?? "")
        }
        guard let meeting = notesMeetingDirectory(for: draft) else { return .editable(draft.notes) }
        if let notes = attachedNotes[draftID] { return .editable(notes) }
        do {
            let notes = try MeetingNotesSidecarFile.read(meetingDirectory: meeting).notes(shownBy: draftID)
            // A meeting folder that is gone (deleted, or replaced by a
            // combine the draft has not been rebound to yet) is not cached.
            if FileManager.default.fileExists(atPath: meeting.path) { attachedNotes[draftID] = notes }
            return .editable(notes)
        } catch {
            Self.logger.error("Meeting notes unreadable for a draft: \(error.localizedDescription, privacy: .public)")
            return .unavailable(error.localizedDescription)
        }
    }

    /// The notes an export of this draft's row carries: exactly what the row
    /// shows, including edits not written yet, each attributed to the draft
    /// it came from (the second meeting's notes after a combine keep theirs).
    public func exportNotes(draftID: UUID) -> Result<[TranscriptExportNote], MeetingNotesExportError> {
        let shown: [MeetingNote]
        switch notes(draftID: draftID) {
        case .editable(let notes): shown = notes
        case .unavailable(let message): return .failure(MeetingNotesExportError(message: message))
        }
        guard let draft = drafts[draftID], let meeting = notesMeetingDirectory(for: draft),
              let sidecar = try? MeetingNotesSidecarFile.read(meetingDirectory: meeting) else {
            return .success(shown.map { TranscriptExportNote($0, draftID: draftID) })
        }
        return .success(sidecar.exportNotes(shown, shownBy: draftID, recorderSessionID: draft.recorderSessionID))
    }

    /// How many notes a draft's row shows.
    public func noteCount(for draftID: UUID) -> Int {
        if case .editable(let notes) = notes(draftID: draftID) { return notes.count }
        return 0
    }

    /// Note counts for every draft, for the list.
    public var noteCounts: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: drafts.keys.map { ($0, noteCount(for: $0)) })
    }

    /// Replaces a draft's notes with what the editor holds. Applied to the
    /// mirror at once and written after a quiet period, to the draft record
    /// before transcription and to the meeting's sidecar after.
    public func setNotes(draftID: UUID, notes: [MeetingNote]) {
        guard let draft = drafts[draftID], case .editable(let current) = self.notes(draftID: draftID), current != notes else { return }
        let countChanged = current.count != notes.count
        if notesMeetingDirectory(for: draft) != nil {
            attachedNotes[draftID] = notes
            dirtySidecars.insert(draftID)
            scheduleSidecarWrite(draftID)
        } else {
            drafts[draftID]?.notes = notes
            pendingDraftNotes[draftID, default: 0] += 1
            let previous = notesChain
            let store = store
            notesChain = Task { [weak self] in
                await previous?.value
                _ = try? await store.update(id: draftID) { $0.notes = notes }
                await self?.finishDraftNotesWrite(draftID)
            }
        }
        if countChanged { didChange?() }
    }

    /// Writes a draft's notes now: at editor close, selection change,
    /// handoff and before combining.
    public func flushNotes(draftID: UUID) async {
        await notesChain?.value
        if dirtySidecars.contains(draftID) { writeSidecar(draftID: draftID) }
        await store.flush(id: draftID)
        await refresh(draftID, onlyIfRowChanged: true)
    }

    /// Whether an edit to this draft's notes or handoff settings made here
    /// has not reached the disk yet, or the last write failed. The floating
    /// notes panel never closes itself while this is true.
    public func hasUnsavedEdits(draftID: UUID) -> Bool {
        (pendingDraftNotes[draftID] ?? 0) > 0
            || (pendingHandoffs[draftID] ?? 0) > 0
            || dirtySidecars.contains(draftID)
            || saveStates[draftID]?.isSaved == false
    }

    /// The recording time for a note written now in this draft, or nil when
    /// it is not the recording being captured, or capture is paused.
    public func noteClock(draftID: UUID) -> Int? {
        guard let draft = drafts[draftID], case .recording = draft.phase,
              let live = liveCapture, live.sessionID == draft.recorderSessionID else { return nil }
        if let captureClock { return captureClock(draft.recorderSessionID) }
        return RecordingTimestamp.noteOffsetMilliseconds(startedAt: live.startedAt, isPaused: live.isPaused, at: Date())
    }

    /// The meeting folder holding a draft's notes, once they belong there:
    /// attached, with no notes left in the draft record. A draft that still
    /// holds notes after attaching (an edit raced the attachment) keeps them
    /// in the record until reconciliation moves them.
    private func notesMeetingDirectory(for draft: MeetingDraft) -> URL? {
        guard case .attached(let meetingKey, _) = draft.phase, draft.notes.isEmpty else { return nil }
        return meetingDirectory(forKey: meetingKey)
    }

    private func meetingDirectory(forKey meetingKey: String) -> URL? {
        transcriptStore?.storeDirectoryURL.appending(path: meetingKey, directoryHint: .isDirectory)
    }

    private func finishDraftNotesWrite(_ id: UUID) async {
        let remaining = (pendingDraftNotes[id] ?? 1) - 1
        pendingDraftNotes[id] = remaining > 0 ? remaining : nil
        guard remaining <= 0, let stored = await store.draft(id: id) else { return }
        // Typing lands here after every keystroke. A reload of the list
        // rereads every transcript in the store, so it is asked for only
        // when a row shows something new; a new note's count was already
        // announced by `setNotes`.
        await refresh(id, onlyIfRowChanged: true)
        // The draft attached while this edit was on its way: move the notes
        // into the meeting now rather than at the next reconciliation.
        if case .attached(let meetingKey, let runID) = stored.phase, !stored.notes.isEmpty {
            await attach(id, meetingKey: meetingKey, runID: runID, recovered: false)
        }
    }

    private func scheduleSidecarWrite(_ id: UUID) {
        sidecarWrites[id]?.cancel()
        let debounce = notesDebounce
        sidecarWrites[id] = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.writeSidecar(draftID: id)
        }
    }

    /// Writes an attached draft's notes into its meeting's sidecar, keeping
    /// every other draft's entry. An unreadable sidecar is left alone and the
    /// draft shows "Not saved"; a meeting that was deleted takes its notes
    /// with it.
    private func writeSidecar(draftID: UUID) {
        sidecarWrites.removeValue(forKey: draftID)?.cancel()
        guard dirtySidecars.contains(draftID) else { return }
        guard let draft = drafts[draftID], let notes = attachedNotes[draftID],
              case .attached(let meetingKey, _) = draft.phase,
              let meeting = meetingDirectory(forKey: meetingKey) else {
            dirtySidecars.remove(draftID)
            return
        }
        let hadError = notesErrors[draftID] != nil
        do {
            var sidecar = try MeetingNotesSidecarFile.read(meetingDirectory: meeting)
            sidecar.setNotes(notes, shownBy: draftID, recorderSessionID: draft.recorderSessionID, revision: draft.revision)
            try MeetingNotesSidecarFile.write(sidecar, meetingDirectory: meeting)
            dirtySidecars.remove(draftID)
            notesErrors[draftID] = nil
        } catch MeetingNotesSidecarFile.FileError.meetingMissing {
            dirtySidecars.remove(draftID)
            notesErrors[draftID] = nil
        } catch {
            notesErrors[draftID] = error.localizedDescription
            Self.logger.error("Meeting notes not saved: \(error.localizedDescription, privacy: .public)")
        }
        if hadError != (notesErrors[draftID] != nil) { didChange?() }
    }

    /// Moves a finished draft's notes into its meeting, then marks it
    /// attached and empties the record's notes, in that order and only if
    /// nothing changed the draft in between. A crash after the sidecar write
    /// re-runs this; writing the same notes again is harmless. A failed write
    /// leaves the draft unattached with its notes, so nothing claims a state
    /// that is not on disk.
    private func attach(_ id: UUID, meetingKey: String, runID: UUID, recovered: Bool) async {
        for _ in 0 ..< 3 {
            guard let current = await store.draft(id: id) else { return }
            var attached: [MeetingNote]?
            if !current.notes.isEmpty {
                guard let meeting = meetingDirectory(forKey: meetingKey) else { return }
                do {
                    var sidecar = try MeetingNotesSidecarFile.read(meetingDirectory: meeting)
                    sidecar.setNotes(current.notes, shownBy: id, recorderSessionID: current.recorderSessionID, revision: current.revision)
                    if let index = sidecar.entries.firstIndex(where: { $0.draftID == id }) {
                        sidecar.entries[index].attachedRevision = current.revision
                    }
                    try MeetingNotesSidecarFile.write(sidecar, meetingDirectory: meeting)
                    attached = sidecar.notes(shownBy: id)
                } catch {
                    notesErrors[id] = error.localizedDescription
                    Self.logger.error("Meeting notes could not be attached: \(error.localizedDescription, privacy: .public)")
                    didChange?()
                    return
                }
            }
            do {
                try await store.update(id: id, expectedRevision: current.revision, flush: true) { draft in
                    draft.phase = .attached(meetingKey: meetingKey, runID: runID)
                    draft.notes = []
                    if recovered { draft.recovered = true }
                }
            } catch MeetingDraftStore.StoreError.staleRevision {
                continue
            } catch {
                return
            }
            notesErrors[id] = nil
            await refresh(id)
            if let attached { attachedNotes[id] = attached }
            return
        }
    }

    private func forgetNotes(_ id: UUID) {
        sidecarWrites.removeValue(forKey: id)?.cancel()
        dirtySidecars.remove(id)
        attachedNotes[id] = nil
        notesErrors[id] = nil
    }

    // MARK: - Handoff settings

    public func handoffSettings(draftID: UUID) -> MeetingHandoffSettings? {
        drafts[draftID]?.handoff
    }

    /// Replaces a draft's handoff settings with what its tray holds. Applied
    /// to the mirror at once and written after the quiet period. Only this
    /// draft changes: every tray is bound to one draft ID.
    public func setHandoffSettings(draftID: UUID, _ settings: MeetingHandoffSettings) {
        guard let current = drafts[draftID], current.handoff != settings else { return }
        let agentChanged = current.handoff.agentID != settings.agentID
        drafts[draftID]?.handoff = settings
        // The row names the agent of a queued send; the rest of the settings
        // (a prompt typed a key at a time) is not news to the list.
        if agentChanged { didChange?() }
        pendingHandoffs[draftID, default: 0] += 1
        let previous = notesChain
        let store = store
        notesChain = Task { [weak self] in
            await previous?.value
            _ = try? await store.update(id: draftID) { $0.handoff = settings }
            await self?.finishHandoffWrite(draftID)
        }
    }

    private func finishHandoffWrite(_ id: UUID) async {
        let remaining = (pendingHandoffs[id] ?? 1) - 1
        pendingHandoffs[id] = remaining > 0 ? remaining : nil
        guard remaining <= 0 else { return }
        // Typing a prompt lands here after every keystroke; only the agent
        // shows in the row.
        await refresh(id, onlyIfRowChanged: true)
    }

    // MARK: - Queued send

    /// Moves a draft's send to `next` if `when` accepts its current state,
    /// and writes it to disk before returning. Returns the draft as stored
    /// when it moved and the write succeeded, else nil: a send transition the
    /// disk does not hold must not be acted on.
    @discardableResult
    public func transitionSend(
        draftID: UUID,
        to next: MeetingSend,
        when accepts: @escaping @Sendable (MeetingSend) -> Bool
    ) async -> MeetingDraft? {
        // Edits typed a moment ago go first, so a claim snapshots them.
        await notesChain?.value
        guard let updated = try? await store.update(id: draftID, flush: true, { draft in
            if accepts(draft.send) { draft.send = next }
        }) else { return nil }
        await refresh(draftID)
        guard updated.send == next, await store.saveState(id: draftID).isSaved else { return nil }
        return updated
    }

    // MARK: - Combining

    /// Readies two meetings' drafts to be combined: refuses while either has
    /// a send under way (decision 12), and writes every pending notes edit so
    /// the combine reads the notes as they are now. Returns why combining
    /// must wait, or nil.
    public func prepareForCombine(draftIDs: [UUID]) async -> String? {
        for id in draftIDs {
            guard let draft = drafts[id] else { continue }
            if draft.send.blocksCombine {
                return "\u{201C}\(draft.effectiveTitle)\u{201D} has a send to an agent under way. Finish or cancel it before combining."
            }
            await flushNotes(draftID: id)
            if let error = notesErrors[id] {
                return "The notes for \u{201C}\(draft.effectiveTitle)\u{201D} could not be saved: \(error)"
            }
            guard let current = drafts[id] else { continue }
            if !current.notes.isEmpty, notesMeetingDirectory(for: current) == nil {
                if case .attached = current.phase {} else {
                    return "The notes for \u{201C}\(draft.effectiveTitle)\u{201D} are still being saved with its transcript. Try again in a moment."
                }
            }
        }
        return nil
    }

    /// Two meetings became one. The draft whose row the combined meeting
    /// keeps loses its handoff settings and send history (decision 12) and
    /// is rebound to the new run by the next reconciliation; the other
    /// draft's record goes, its notes having moved into the new meeting.
    public func finishCombine(ownerDraftID: UUID?, absorbedDraftIDs: [UUID]) async {
        if let ownerDraftID, drafts[ownerDraftID] != nil {
            attachedNotes[ownerDraftID] = nil
            await mutate(ownerDraftID, flush: true) { draft in
                draft.handoff = MeetingHandoffSettings()
                draft.send = .notQueued
            }
        }
        for id in absorbedDraftIDs where id != ownerDraftID {
            try? await deleteDraft(draftID: id)
        }
    }

    // MARK: - Mirror

    private func mutate(_ id: UUID, flush: Bool = false, _ change: @escaping @Sendable (inout MeetingDraft) -> Void) async {
        _ = try? await store.update(id: id, flush: flush, change)
        await refresh(id)
    }

    /// Takes the store's copy of a draft into the mirror and tells review.
    /// `onlyIfRowChanged` skips the telling when nothing a row shows (the
    /// facts `rowFacts` keeps, and the save state) is different.
    private func refresh(_ id: UUID, onlyIfRowChanged: Bool = false) async {
        guard !deletedIDs.contains(id) else { return }
        let before = drafts[id].map(Self.rowFacts)
        let saveStateBefore = saveStates[id]
        if let draft = await store.draft(id: id) {
            adopt(draft)
            storeSaveStates[id] = await store.saveState(id: id)
        }
        if onlyIfRowChanged, before != nil, before == drafts[id].map(Self.rowFacts), saveStateBefore == saveStates[id] {
            return
        }
        didChange?()
    }

    private func apply(_ change: MeetingDraftStore.Change) {
        guard !deletedIDs.contains(change.draftID) else { return }
        guard let incoming = change.draft else {
            drafts[change.draftID] = nil
            storeSaveStates[change.draftID] = nil
            forgetNotes(change.draftID)
            didChange?()
            return
        }
        if let current = drafts[change.draftID], current.revision > incoming.revision { return }
        let before = drafts[change.draftID]
        let saveStateChanged = storeSaveStates[change.draftID] != change.saveState
        adopt(incoming)
        storeSaveStates[change.draftID] = change.saveState
        // Typing changes the notes and the revision on every keystroke; the
        // list only needs to hear about it when what a row shows changes.
        if saveStateChanged || before.map({ Self.rowFacts($0) }) != Self.rowFacts(drafts[change.draftID]!) {
            didChange?()
        }
    }

    /// Takes the store's copy of a draft into the mirror. Notes still being
    /// written from here stay as typed; a move to another meeting drops the
    /// notes read from the old one.
    private func adopt(_ incoming: MeetingDraft) {
        var draft = incoming
        if pendingDraftNotes[draft.id] != nil, let local = drafts[draft.id]?.notes {
            draft.notes = local
        }
        if pendingHandoffs[draft.id] != nil, let local = drafts[draft.id]?.handoff {
            draft.handoff = local
        }
        if drafts[draft.id]?.phase != draft.phase {
            attachedNotes[draft.id] = nil
        }
        drafts[draft.id] = draft
    }

    /// Everything about a draft a row shows, ignoring note text, revision and
    /// handoff settings (typed into the tray, read by the tray itself).
    private static func rowFacts(_ draft: MeetingDraft) -> MeetingDraft {
        var facts = draft
        facts.revision = 0
        // A queued send's row names the agent; nothing else of the handoff shows.
        facts.handoff = MeetingHandoffSettings()
        facts.handoff.agentID = draft.handoff.agentID
        facts.notes = draft.notes.map { MeetingNote(id: $0.id, text: "", recordingOffsetMilliseconds: nil) }
        return facts
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
