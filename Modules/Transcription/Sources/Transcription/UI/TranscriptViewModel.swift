import Foundation
import Observation
import ScribeAppCore
import Speakers

/// Fixture-first state and actions for the transcript review window.
@MainActor
@Observable
public final class TranscriptViewModel {
    public private(set) var files: [TranscriptReviewFile]
    public var selectedFileID: TranscriptReviewFile.ID? {
        didSet { selectFileIfNeeded() }
    }
    public private(set) var selectedSegmentID: TranscriptSegment.ID?
    public private(set) var exportOutcomes: [TranscriptExportOutcome] = []

    /// People available to the speaker picker, refreshed from the library.
    public private(set) var people: [SpeakerPersonRef] = []
    public private(set) var speakerActionMessage: TranscriptSpeakerActionMessage?
    /// Speaker-count reprocess confirmation and progress sheet, when one is open.
    public private(set) var reprocessSession: TranscriptReprocessSession?
    /// Candidate excerpts for the in-progress "Remember this voice" action.
    public private(set) var enrollmentCandidates: [TranscriptEnrollmentCandidate] = []
    public private(set) var enrollmentSpeakerID: String?
    public private(set) var isEnrolling = false

    /// The turn playback is on, or nil when stopped. Set only through the
    /// transport actions so the bar, the rows, and the player never disagree.
    public private(set) var playingSegmentID: TranscriptSegment.ID?
    public private(set) var isPlaying = false
    /// Where the play head is in the source, updated as it moves and on seek.
    public private(set) var playheadMilliseconds = 0
    public private(set) var playbackRate: Float = 1
    /// Whether the list scrolls to keep the playing turn in view.
    public var followsPlayback = true

    /// Words to find in the transcript; empty shows every turn.
    public var searchText = ""
    /// Show only this recording-local speaker's turns, or nil for everyone.
    public var speakerFilterID: String?
    public var reviewFilter: TranscriptReviewFilter = .all
    /// Segments for precise review, or paragraphs derived for reading.
    public var reviewLayout: TranscriptReviewLayout = .segments

    /// Earlier revisions of each file, most recent last, for undo; and the
    /// ones undone, for redo. Kept in memory only: every step is also a saved
    /// revision, so nothing is lost when the window closes.
    @ObservationIgnored private var undoStacks: [TranscriptReviewFile.ID: [CanonicalTranscript]] = [:]
    @ObservationIgnored private var redoStacks: [TranscriptReviewFile.ID: [CanonicalTranscript]] = [:]

    @ObservationIgnored private let playback: any TranscriptPlaybackSeeking
    @ObservationIgnored private let exportWriter: any TranscriptExportWriting
    @ObservationIgnored private let directory: (any TranscriptSpeakerDirectory)?
    @ObservationIgnored private let revisionStore: (any TranscriptRevisionStoring)?
    @ObservationIgnored private let fileDeleter: (any TranscriptFileDeleting)?
    @ObservationIgnored private let fileImporter: (any TranscriptFileImporting)?
    @ObservationIgnored private let reprocessor: (any TranscriptReprocessing)?
    @ObservationIgnored private let retranscriber: (any TranscriptRetranscribing)?
    /// Hands a finished transcript to a coding agent. Absent in a build with no
    /// agent host, which hides the action rather than offering a dead end.
    @ObservationIgnored private let agentDispatcher: (any TranscriptAgentDispatching)?
    /// Opens the vocabulary editor in the host's Settings window. Absent in a
    /// build with no settings surface — the toolbar then hides the button
    /// rather than offering a route that goes nowhere.
    @ObservationIgnored private let openVocabularySettings: (@MainActor () -> Void)?

    /// The outcome of the last drop, shown in the sidebar until the next one.
    public private(set) var importMessage: TranscriptSpeakerActionMessage?
    /// True while dropped files are being probed and queued.
    public private(set) var isImporting = false

    /// What the host found for the send sheet, or nil until it has been asked.
    public private(set) var agentEnvironment: TranscriptAgentEnvironment?
    public var selectedAgentID: TranscriptAgent.ID?
    public var selectedAgentFolderID: TranscriptAgentFolder.ID?
    /// What the person wants done with the transcript. Empty means the default.
    public var agentInstruction = ""
    /// True while the agent's session is being created.
    public private(set) var isSendingToAgent = false
    /// The outcome of the last send, shown until the next one.
    public private(set) var agentMessage: TranscriptSpeakerActionMessage?

    public init(
        files: [TranscriptReviewFile],
        selectedFileID: TranscriptReviewFile.ID? = nil,
        playback: any TranscriptPlaybackSeeking,
        exportWriter: any TranscriptExportWriting = FileTranscriptExportWriter(),
        directory: (any TranscriptSpeakerDirectory)? = nil,
        revisionStore: (any TranscriptRevisionStoring)? = nil,
        fileDeleter: (any TranscriptFileDeleting)? = nil,
        fileImporter: (any TranscriptFileImporting)? = nil,
        reprocessor: (any TranscriptReprocessing)? = nil,
        retranscriber: (any TranscriptRetranscribing)? = nil,
        agentDispatcher: (any TranscriptAgentDispatching)? = nil,
        openVocabularySettings: (@MainActor () -> Void)? = nil
    ) {
        self.files = files
        self.selectedFileID = selectedFileID ?? files.first?.id
        self.playback = playback
        self.exportWriter = exportWriter
        self.directory = directory
        self.revisionStore = revisionStore
        self.fileDeleter = fileDeleter
        self.fileImporter = fileImporter
        self.reprocessor = reprocessor
        self.retranscriber = retranscriber
        self.agentDispatcher = agentDispatcher
        self.openVocabularySettings = openVocabularySettings
        selectFileIfNeeded()
        playback.setPlaybackObserver { [weak self] event in self?.handle(event) }
    }

    /// Whether the review window can send someone to the vocabulary editor.
    public var canOpenVocabularySettings: Bool { openVocabularySettings != nil }

    /// Sends the person to Settings, at the vocabulary. Editing the list here
    /// would be the wrong place: the list is not a property of this transcript,
    /// and a change to it applies to transcriptions made afterwards.
    public func openVocabulary() {
        openVocabularySettings?()
    }

    /// Replaces the list as the job pipeline reports new state.
    ///
    /// The selection is a person's place in the window, not derived state, so it
    /// survives a refresh whenever the file it names is still present. A file
    /// whose transcript has been relabelled in this window keeps the revision on
    /// screen when the incoming copy is not newer, so a routine refresh cannot
    /// silently discard an edit that is still being made.
    public func reload(files incoming: [TranscriptReviewFile]) {
        let previousSelection = selectedFile
        let edited = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.files = incoming.map { file in
            guard let existing = edited[file.id],
                  let existingTranscript = existing.transcript,
                  let incomingTranscript = file.transcript,
                  existingTranscript.revision > incomingTranscript.revision
            else { return file }
            return file.replacingTranscript(existingTranscript)
        }
        if let selectedFileID, self.files.contains(where: { $0.id == selectedFileID }) { return }
        // A finished reprocess replaces the run ID; keep the same source selected
        // so the confirmation sheet and review stay on the meeting that just finished.
        if let previousSelection,
           let replacement = self.files.first(where: {
               $0.sourceSnapshotURL.standardizedFileURL == previousSelection.sourceSnapshotURL.standardizedFileURL
           })
        {
            self.selectedFileID = replacement.id
            return
        }
        selectedFileID = self.files.first?.id
    }

    public var selectedFile: TranscriptReviewFile? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    public var selectedTranscript: CanonicalTranscript? { selectedFile?.transcript }

    public var chronologicalSegments: [TranscriptSegment] {
        (selectedTranscript?.segments ?? []).sorted {
            ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id)
        }
    }

    /// Reading paragraphs derived from the current canonical segments.
    public var chronologicalParagraphs: [TranscriptParagraph] {
        TranscriptParagraphGrouper().paragraphs(from: chronologicalSegments)
    }

    /// The speakers this recording has, in table order.
    public var recordingSpeakers: [TranscriptSpeaker] { selectedTranscript?.speakers ?? [] }

    public var sourceDurationMilliseconds: Int { selectedTranscript?.source.durationMs ?? 0 }

    /// The turns the list shows after search and filters.
    public var visibleSegments: [TranscriptSegment] {
        let query = Self.normalizedSearch(searchText)
        return chronologicalSegments.filter { segment in
            if let speakerFilterID, segment.effectiveSpeakerID != speakerFilterID { return false }
            guard reviewFilter.matches(segment) else { return false }
            guard !query.isEmpty else { return true }
            return Self.normalizedSearch(segment.text).contains(query)
                || Self.normalizedSearch(segment.speakerLabel).contains(query)
        }
    }

    /// The reading paragraphs the list shows after search and filters.
    public var visibleParagraphs: [TranscriptParagraph] {
        let query = Self.normalizedSearch(searchText)
        return chronologicalParagraphs.filter { paragraph in
            if let speakerFilterID, paragraph.speakerID != speakerFilterID,
               !paragraph.asides.contains(where: { $0.speakerID == speakerFilterID }) { return false }
            guard reviewFilter.matches(paragraph) else { return false }
            guard !query.isEmpty else { return true }
            return Self.normalizedSearch(paragraph.text).contains(query)
                || Self.normalizedSearch(paragraph.speakerLabel).contains(query)
                || paragraph.asides.contains { aside in
                    Self.normalizedSearch(aside.text).contains(query)
                        || Self.normalizedSearch(aside.speakerLabel).contains(query)
                }
        }
    }

    /// The list row that currently owns the play head, in the active layout.
    public var playingRowID: String? {
        switch reviewLayout {
        case .segments: playingSegmentID
        case .paragraphs: playingParagraphID
        }
    }

    /// The list row that is selected, in the active layout.
    public var selectedRowID: String? {
        switch reviewLayout {
        case .segments: selectedSegmentID
        case .paragraphs: selectedParagraphID
        }
    }

    public var selectedParagraphID: TranscriptParagraph.ID? {
        paragraph(containingSegmentID: selectedSegmentID)?.id
    }

    public var playingParagraphID: TranscriptParagraph.ID? {
        paragraph(containingSegmentID: playingSegmentID)?.id
    }

    public var isFiltering: Bool {
        !Self.normalizedSearch(searchText).isEmpty || speakerFilterID != nil || reviewFilter != .all
    }

    public var segmentsNeedingReviewCount: Int {
        chronologicalSegments.filter(\.needsReview).count
    }

    /// A one-line account of the recording: turns, paragraphs, speakers, and length.
    public var reviewSummary: String? {
        guard let transcript = selectedTranscript else { return nil }
        let turns = transcript.segments.count
        let paragraphs = chronologicalParagraphs.count
        let speakers = transcript.speakers.count
        var parts = [
            "\(turns) turn\(turns == 1 ? "" : "s")",
            "\(paragraphs) paragraph\(paragraphs == 1 ? "" : "s")",
            "\(speakers) speaker\(speakers == 1 ? "" : "s")",
            TranscriptTimecode.string(fromMilliseconds: transcript.source.durationMs).replacingOccurrences(of: #"\.\d{3}$"#, with: "", options: .regularExpression),
        ]
        if transcript.title != nil { parts.append(transcript.source.filename) }
        return parts.joined(separator: " · ")
    }

    /// Case- and accent-insensitive comparison key for search.
    public static func normalizedSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var languageDescription: String? {
        guard let transcript = selectedTranscript else { return nil }
        let provenance: String = switch transcript.languageSource {
        case .detected: "detected"
        case .userProvided: "user-provided"
        case .unknown: "unknown"
        }
        return "Language: \(transcript.language) (\(provenance))"
    }

    public var timingLimitation: String? {
        guard let transcript = selectedTranscript else { return nil }
        guard transcript.segments.contains(where: { $0.timingQuality == .segmentOnly }) else { return nil }
        return "Some timestamps are segment-level estimates rather than word-aligned timings."
    }

    public var processingMessages: [String] {
        var messages = selectedTranscript?.warnings.map(\.message) ?? []
        if let error = selectedFile?.processingError { messages.insert(error, at: 0) }
        if case .failed(let message) = selectedFile?.jobState { messages.insert(message, at: 0) }
        return Array(NSOrderedSet(array: messages)) as? [String] ?? messages
    }

    public func select(segment: TranscriptSegment, seekToStart: Bool = true) {
        selectedSegmentID = segment.id
        if seekToStart {
            playheadMilliseconds = segment.startMs
            playback.seek(toMilliseconds: segment.startMs)
        }
        // A seek while playing moves the readout with the audio; a seek while
        // paused or stopped is only a selection and must not start sound.
        if isPlaying { playingSegmentID = segment.id }
    }

    /// Selects the paragraph without rewriting canonical segments. The play head
    /// stays put when it already sits inside the paragraph.
    public func select(paragraph: TranscriptParagraph) {
        guard let segment = primarySegment(for: paragraph) else { return }
        let playheadInside = playheadMilliseconds >= paragraph.startMs && playheadMilliseconds <= paragraph.endMs
        select(segment: segment, seekToStart: !playheadInside)
    }

    public func play(paragraph: TranscriptParagraph) {
        guard let segment = chronologicalSegments.first(where: { $0.id == paragraph.sourceSegmentIDs.first }) else {
            return
        }
        play(segment: segment)
    }

    public func paragraph(containingSegmentID segmentID: TranscriptSegment.ID?) -> TranscriptParagraph? {
        guard let segmentID else { return nil }
        return chronologicalParagraphs.first { $0.allSourceSegmentIDs.contains(segmentID) }
    }

    /// The canonical segment a paragraph row should act on: the selected source
    /// when it belongs to the paragraph, otherwise the source covering the play
    /// head, otherwise the first source.
    public func primarySegment(for paragraph: TranscriptParagraph) -> TranscriptSegment? {
        let sources = chronologicalSegments.filter { paragraph.sourceSegmentIDs.contains($0.id) }
        guard !sources.isEmpty else { return nil }
        if let selectedSegmentID, let selected = sources.first(where: { $0.id == selectedSegmentID }) {
            return selected
        }
        if playheadMilliseconds >= paragraph.startMs, playheadMilliseconds <= paragraph.endMs {
            return sources.last { $0.startMs <= playheadMilliseconds } ?? sources.first
        }
        return sources.first
    }

    // MARK: - Playback

    /// What the transport bar shows, or nil when playback is stopped.
    public var playbackStatus: TranscriptPlaybackStatus? {
        guard let playingSegmentID,
              let segment = chronologicalSegments.first(where: { $0.id == playingSegmentID })
        else { return nil }
        return TranscriptPlaybackStatus(segment: segment, isPlaying: isPlaying)
    }

    /// Starts playing from this turn and keeps going through the turns that
    /// follow until the transcript ends or the person stops it.
    public func play(segment: TranscriptSegment) {
        selectedSegmentID = segment.id
        playingSegmentID = segment.id
        playheadMilliseconds = segment.startMs
        playback.seek(toMilliseconds: segment.startMs)
        playback.play()
        isPlaying = true
    }

    /// The bar's one button: pause while playing, resume while paused, and
    /// otherwise start from the selected turn or the top of the transcript.
    public func togglePlayback() {
        if isPlaying {
            playback.pause()
            isPlaying = false
            return
        }
        if playingSegmentID != nil {
            playback.play()
            isPlaying = true
            return
        }
        let segments = chronologicalSegments
        guard let start = segments.first(where: { $0.id == selectedSegmentID }) ?? segments.first else { return }
        play(segment: start)
    }

    /// Stops and forgets the position, so the next play starts from the
    /// selected turn rather than resuming mid-word.
    public func stopPlayback() {
        guard isPlaying || playingSegmentID != nil else { return }
        playback.pause()
        isPlaying = false
        playingSegmentID = nil
    }

    /// Moves the play head to a time in the source, whether or not it is playing.
    ///
    /// While playing or paused the readout follows to the turn at that time.
    /// While stopped the turn there becomes the selection, so the next play
    /// starts where the scrubber was left.
    public func seek(toMilliseconds milliseconds: Int) {
        let clamped = max(0, min(milliseconds, max(0, sourceDurationMilliseconds)))
        playheadMilliseconds = clamped
        playback.seek(toMilliseconds: clamped)
        guard let current = chronologicalSegments.last(where: { $0.startMs <= clamped }) ?? chronologicalSegments.first else { return }
        selectedSegmentID = current.id
        if playingSegmentID != nil { playingSegmentID = current.id }
    }

    /// Nudges the play head by `milliseconds`, negative to go back.
    public func skip(byMilliseconds milliseconds: Int) {
        seek(toMilliseconds: playheadMilliseconds + milliseconds)
    }

    public func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        playback.setRate(rate)
    }

    /// Plays the selected turn, or pauses when it is already playing.
    public func playSelectedOrToggle() {
        if isPlaying { togglePlayback(); return }
        if let playingSegmentID, playingSegmentID == selectedSegmentID { togglePlayback(); return }
        guard let segment = chronologicalSegments.first(where: { $0.id == selectedSegmentID }) else {
            togglePlayback()
            return
        }
        play(segment: segment)
    }

    /// Moves the selection through the visible turns; the play head follows
    /// only while playback is running, so browsing stays silent.
    public func selectNeighbouringSegment(offset: Int) {
        if reviewLayout == .paragraphs {
            selectNeighbouringParagraph(offset: offset)
            return
        }
        let segments = visibleSegments
        guard !segments.isEmpty else { return }
        guard let selectedSegmentID, let index = segments.firstIndex(where: { $0.id == selectedSegmentID }) else {
            select(segment: offset < 0 ? segments[segments.count - 1] : segments[0])
            return
        }
        let target = max(0, min(segments.count - 1, index + offset))
        guard target != index else { return }
        if isPlaying { play(segment: segments[target]) } else { select(segment: segments[target]) }
    }

    /// Selects the next turn after the selection that needs a look, wrapping
    /// to the top; returns false when nothing does.
    @discardableResult
    public func selectNextSegmentNeedingReview() -> Bool {
        if reviewLayout == .paragraphs {
            return selectNextParagraphNeedingReview()
        }
        let segments = chronologicalSegments
        let candidates = segments.filter(\.needsReview)
        guard !candidates.isEmpty else { return false }
        let start = segments.firstIndex { $0.id == selectedSegmentID } ?? -1
        let next = segments.enumerated().first { $0.offset > start && $0.element.needsReview }?.element
            ?? candidates[0]
        select(segment: next)
        return true
    }

    private func selectNeighbouringParagraph(offset: Int) {
        let paragraphs = visibleParagraphs
        guard !paragraphs.isEmpty else { return }
        guard let selectedParagraphID, let index = paragraphs.firstIndex(where: { $0.id == selectedParagraphID }) else {
            select(paragraph: offset < 0 ? paragraphs[paragraphs.count - 1] : paragraphs[0])
            return
        }
        let target = max(0, min(paragraphs.count - 1, index + offset))
        guard target != index else { return }
        if isPlaying { play(paragraph: paragraphs[target]) } else { select(paragraph: paragraphs[target]) }
    }

    @discardableResult
    private func selectNextParagraphNeedingReview() -> Bool {
        let paragraphs = chronologicalParagraphs
        let candidates = paragraphs.filter(\.needsReview)
        guard !candidates.isEmpty else { return false }
        let start = paragraphs.firstIndex { $0.id == selectedParagraphID } ?? -1
        let next = paragraphs.enumerated().first { $0.offset > start && $0.element.needsReview }?.element
            ?? candidates[0]
        select(paragraph: next)
        return true
    }

    private func handle(_ event: TranscriptPlaybackEvent) {
        if case .timeChanged(let milliseconds) = event { playheadMilliseconds = milliseconds }
        guard isPlaying else { return }
        switch event {
        case .ended:
            stopPlayback()
        case .timeChanged(let milliseconds):
            let segments = chronologicalSegments
            guard let last = segments.last else { return }
            if milliseconds >= last.endMs {
                stopPlayback()
                return
            }
            // The turn that most recently started owns the play head; during a
            // pause between turns the readout keeps the speaker who just spoke
            // rather than blanking.
            guard let current = segments.last(where: { $0.startMs <= milliseconds }) else { return }
            if current.id != playingSegmentID {
                playingSegmentID = current.id
                selectedSegmentID = current.id
            }
        }
    }

    // MARK: - Deleting

    /// Whether the sidebar offers to delete this file. A job still in flight is
    /// left to the coordinator: pulling its directory out from under it is
    /// worse than waiting for it to finish or fail.
    public func canDelete(_ file: TranscriptReviewFile) -> Bool {
        switch file.jobState {
        case .ready, .queued, .processing: false
        case .complete, .completeWithWarnings, .noSpeech, .failed: true
        }
    }

    /// Removes the file from the host store and the list. When it was the one
    /// on screen, playback stops and the selection moves to its neighbour.
    public func delete(fileID: TranscriptReviewFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == fileID }), canDelete(files[index]) else { return }
        let file = files[index]
        do {
            try fileDeleter?.delete(fileID: fileID)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Could not delete \(file.filename): \(Self.describe(error))",
                isFailure: true
            )
            return
        }
        files.remove(at: index)
        if selectedFileID == fileID {
            let neighbour = files.indices.contains(index) ? files[index] : files.last
            selectedFileID = neighbour?.id
        }
    }

    // MARK: - Importing

    /// Whether the sidebar accepts dropped files at all. Without a host
    /// importer there is nowhere to queue them, so the drop is refused up
    /// front rather than accepted and silently lost.
    public var canImportFiles: Bool { fileImporter != nil }

    /// Whether the toolbar offers speaker-count reprocess. An in-flight job or
    /// an open reprocess sheet blocks another queue until that one settles.
    public var canReprocess: Bool {
        guard reprocessor != nil, let file = selectedFile, reprocessSession == nil else { return false }
        switch file.jobState {
        case .ready, .queued, .processing: return false
        case .complete, .completeWithWarnings, .noSpeech, .failed: return true
        }
    }

    /// Whether the sidebar offers to retranscribe this file. A job still in
    /// flight is left alone: queuing another full run of the same source while
    /// its first pass is writing checkpoints is more confusing than useful.
    public func canRetranscribe(_ file: TranscriptReviewFile) -> Bool {
        guard retranscriber != nil else { return false }
        switch file.jobState {
        case .ready, .queued, .processing: return false
        case .complete, .completeWithWarnings, .noSpeech, .failed: return true
        }
    }

    /// Opens the confirmation sheet for a chosen speaker count. The run is not
    /// queued until the person confirms on that screen.
    public func presentReprocessConfirmation(speakerCount: TranscriptionSpeakerCount) {
        guard canReprocess, let file = selectedFile else { return }
        reprocessSession = TranscriptReprocessSession(
            fileID: file.id,
            displayName: file.displayName,
            speakerCount: speakerCount
        )
    }

    /// Closes the reprocess sheet. An already-queued run keeps going; progress
    /// simply stops being shown here.
    public func dismissReprocessSession() {
        reprocessSession = nil
    }

    /// Queues the confirmed speaker-count reprocess and moves the sheet into
    /// its progress phase.
    public func confirmReprocess() async {
        guard let reprocessor,
              let session = reprocessSession,
              session.phase == .confirming
        else { return }
        let outcome = await reprocessor.reprocess(fileID: session.fileID, speakerCount: session.speakerCount)
        speakerActionMessage = TranscriptSpeakerActionMessage(text: outcome.message, isFailure: outcome.isFailure)
        guard var current = reprocessSession, current.id == session.id else { return }
        if outcome.isFailure {
            current.phase = .failed(message: outcome.message)
            reprocessSession = current
            return
        }
        current.queuedRunID = outcome.queuedRunID
        current.phase = .queued
        reprocessSession = current
    }

    /// Applies a coordinator stage update to the open reprocess sheet when the
    /// event belongs to the run that sheet queued.
    public func applyReprocessProgress(runID: String, stage: TranscriptionJobState) {
        guard var session = reprocessSession, session.queuedRunID == runID else { return }
        session.phase = .processing(stageLabel: stage.progressLabel, progress: stage.progressFractionOnStart)
        reprocessSession = session
    }

    /// Marks a tracked reprocess stage as checkpointed for progress fraction.
    public func applyReprocessCheckpoint(runID: String, stage: TranscriptionJobState) {
        guard var session = reprocessSession, session.queuedRunID == runID else { return }
        session.phase = .processing(stageLabel: stage.progressLabel, progress: stage.progressFractionOnCheckpoint)
        reprocessSession = session
    }

    /// Ends a tracked reprocess when the queued run finishes or fails.
    public func finishReprocess(runID: String, success: Bool, message: String? = nil) {
        guard var session = reprocessSession, session.queuedRunID == runID else { return }
        if success {
            session.phase = .complete
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Finished re-transcribing with \(session.speakerCountDescription).",
                isFailure: false
            )
        } else {
            let failure = message ?? "Re-transcription failed."
            session.phase = .failed(message: failure)
            speakerActionMessage = TranscriptSpeakerActionMessage(text: failure, isFailure: true)
        }
        reprocessSession = session
    }

    /// Re-runs recognition and diarization with the host's current models and
    /// settings. The reviewed transcript stays on screen until the new run
    /// finishes and becomes the latest for that source.
    public func retranscribe(fileID: TranscriptReviewFile.ID) async {
        guard let retranscriber, let file = files.first(where: { $0.id == fileID }), canRetranscribe(file) else { return }
        let outcome = await retranscriber.retranscribe(fileID: fileID)
        speakerActionMessage = TranscriptSpeakerActionMessage(text: outcome.message, isFailure: outcome.isFailure)
    }

    /// Hands files dropped on the window to the host for transcription.
    ///
    /// The list is not touched here: the host refreshes it from the store once
    /// the jobs exist, which keeps a dropped file on the same path as one from a
    /// folder import or a finished recording. Only the outcome is kept, so the
    /// person sees what happened to what they dropped.
    public func importFiles(at urls: [URL]) async {
        guard let fileImporter, !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        let outcome = await fileImporter.importFiles(at: urls)
        importMessage = TranscriptSpeakerActionMessage(text: outcome.summary, isFailure: outcome.isFailure)
    }

    public func dismissImportMessage() {
        importMessage = nil
    }

    /// Exports each requested format separately so an SRT failure does not lose valid TXT/JSON.
    public func export(_ formats: Set<TranscriptExportFormat>, to directoryURL: URL, basename: String? = nil) {
        guard let transcript = selectedTranscript else {
            exportOutcomes = formats.map {
                TranscriptExportOutcome(format: $0, destinationURL: nil, errorMessage: "This file has no completed transcript to export.")
            }
            return
        }
        let name = basename ?? FileTranscriptExportWriter.basename(for: transcript)
        exportOutcomes = exportWriter.write(transcript, formats: formats, to: directoryURL, basename: name)
    }

    /// Writes one format to the exact file the Save panel chose, including a renamed file.
    public func export(_ format: TranscriptExportFormat, toFile fileURL: URL) {
        guard let transcript = selectedTranscript else {
            exportOutcomes = [
                TranscriptExportOutcome(
                    format: format,
                    destinationURL: nil,
                    errorMessage: "This file has no completed transcript to export."
                )
            ]
            return
        }
        exportOutcomes = [exportWriter.write(transcript, format: format, toFile: fileURL)]
    }

    /// Brings saved labels up to date with the library, then exports that revision.
    public func exportRefreshingLabels(
        _ formats: Set<TranscriptExportFormat>,
        to directoryURL: URL,
        basename: String? = nil
    ) async {
        await refreshLabelsFromLibrary(announceUnchanged: false)
        export(formats, to: directoryURL, basename: basename)
    }

    /// Brings saved labels up to date with the library, then writes one format to `fileURL`.
    public func exportRefreshingLabels(_ format: TranscriptExportFormat, toFile fileURL: URL) async {
        await refreshLabelsFromLibrary(announceUnchanged: false)
        export(format, toFile: fileURL)
    }

    // MARK: - Sending to an agent

    /// Whether the window offers the send action at all. Without a host
    /// dispatcher there is nothing to send to, so the toolbar leaves it out
    /// rather than opening a sheet that can do nothing.
    public var canSendToAgent: Bool { agentDispatcher != nil }

    public var agents: [TranscriptAgent] { agentEnvironment?.agents ?? [] }
    public var agentFolders: [TranscriptAgentFolder] { agentEnvironment?.folders ?? [] }

    public var selectedAgent: TranscriptAgent? {
        agents.first { $0.id == selectedAgentID }
    }

    public var selectedAgentFolder: TranscriptAgentFolder? {
        agentFolders.first { $0.id == selectedAgentFolderID }
    }

    /// Why the send button is not available yet, in the person's terms, or nil
    /// when everything it needs is chosen. The sheet shows this rather than
    /// leaving a disabled button unexplained.
    public var agentHandoffProblem: String? {
        if let reason = agentEnvironment?.unavailableReason { return reason }
        if selectedTranscript == nil { return "This file has no completed transcript to send." }
        if agents.isEmpty { return "No coding agent was found on this Mac." }
        if agentFolders.isEmpty { return "Connect the folder the agent should work in." }
        if selectedAgent == nil { return "Choose an agent." }
        guard let folder = selectedAgentFolder else { return "Choose a folder." }
        if !folder.isReachable { return "\(folder.displayName) is no longer where it was. Connect it again." }
        return nil
    }

    public var canSubmitAgentHandoff: Bool { agentHandoffProblem == nil && !isSendingToAgent }

    /// Asks the host what is available and keeps the two choices valid.
    ///
    /// Called each time the sheet opens: an agent can be installed and a folder
    /// moved between one sending and the next, and a selection that no longer
    /// names anything must not survive as an invisible choice.
    public func loadAgentEnvironment() async {
        guard let agentDispatcher else { return }
        apply(await agentDispatcher.environment())
    }

    /// Sends the person to the host's folder chooser, then selects whatever
    /// came back so the folder they just connected is the one that is used.
    public func connectAgentFolder() async {
        guard let agentDispatcher else { return }
        let known = Set(agentFolders.map(\.id))
        let environment = await agentDispatcher.connectFolder()
        apply(environment)
        if let connected = environment.folders.first(where: { !known.contains($0.id) }) {
            selectedAgentFolderID = connected.id
        }
    }

    public func disconnectAgentFolder(id: TranscriptAgentFolder.ID) async {
        guard let agentDispatcher else { return }
        apply(await agentDispatcher.disconnectFolder(id: id))
    }

    /// Brings saved labels up to date with the library, then starts the agent on
    /// that revision. Labels are refreshed first for the same reason exporting
    /// refreshes them: the agent should read the names the library holds now,
    /// not the ones diarization guessed.
    ///
    /// Returns whether the session was created, so the sheet can close on
    /// success and stay open with the reason on failure.
    @discardableResult
    public func sendToAgent() async -> Bool {
        guard let agentDispatcher, canSubmitAgentHandoff else { return false }
        await refreshLabelsFromLibrary(announceUnchanged: false)
        guard let transcript = selectedTranscript, let agent = selectedAgent, let folder = selectedAgentFolder else { return false }
        isSendingToAgent = true
        defer { isSendingToAgent = false }
        let outcome = await agentDispatcher.send(TranscriptAgentRequest(
            transcript: transcript,
            agent: agent,
            folder: folder,
            instruction: agentInstruction
        ))
        agentMessage = TranscriptSpeakerActionMessage(text: outcome.summary, isFailure: !outcome.succeeded)
        return outcome.succeeded
    }

    public func dismissAgentMessage() {
        agentMessage = nil
    }

    /// Adopts a refreshed environment, moving each selection onto something
    /// that still exists rather than leaving it naming an agent or folder that
    /// has gone.
    private func apply(_ environment: TranscriptAgentEnvironment) {
        agentEnvironment = environment
        if selectedAgentID == nil || !environment.agents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = environment.agents.first?.id
        }
        if selectedAgentFolderID == nil || !environment.folders.contains(where: { $0.id == selectedAgentFolderID }) {
            selectedAgentFolderID = environment.folders.first(where: \.isReachable)?.id ?? environment.folders.first?.id
        }
    }

    // MARK: - Naming

    /// Gives the transcript a name of its own, or clears it back to the source
    /// filename with nil. Like every edit, this is a saved revision.
    public func rename(to title: String?) {
        applyEdit({ try TranscriptSegmentEditor.renaming(to: title, in: $0) }) { revised in
            revised.title.map { "Renamed to \u{201C}\($0)\u{201D}." } ?? "Cleared the name; the transcript goes by its source filename."
        }
    }

    // MARK: - Editing turns

    /// The units a turn can be split between, for the split sheet.
    public func splitTokens(for segment: TranscriptSegment) -> [TranscriptSplitToken] {
        TranscriptSegmentEditor.splitTokens(for: segment)
    }

    /// Splits a turn into two before the token at `tokenIndex`; the earlier
    /// half stays selected.
    public func split(segmentID: String, beforeToken tokenIndex: Int) {
        applyEdit({ try TranscriptSegmentEditor.splitting(segmentID: segmentID, beforeToken: tokenIndex, in: $0) }) { _ in
            "Split the turn in two."
        }
        selectedSegmentID = chronologicalSegments.first { $0.id.hasPrefix(segmentID + ".") }?.id ?? selectedSegmentID
    }

    /// The turn after this one in time, if any.
    public func segment(after segmentID: String) -> TranscriptSegment? {
        let segments = chronologicalSegments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), index + 1 < segments.count else { return nil }
        return segments[index + 1]
    }

    /// The turn before this one in time, if any.
    public func segment(before segmentID: String) -> TranscriptSegment? {
        let segments = chronologicalSegments
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), index > 0 else { return nil }
        return segments[index - 1]
    }

    /// Combines a turn with its neighbour into one. The earlier turn's speaker
    /// is kept; when the two disagreed the message says so.
    public func merge(segmentID: String, withNext: Bool) {
        guard let neighbour = withNext ? segment(after: segmentID) : segment(before: segmentID),
              let segment = chronologicalSegments.first(where: { $0.id == segmentID }) else {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: withNext ? "This is already the last turn." : "This is already the first turn.",
                isFailure: true
            )
            return
        }
        let earlier = withNext ? segment : neighbour
        let later = withNext ? neighbour : segment
        applyEdit({ try TranscriptSegmentEditor.merging(segmentID: segmentID, with: neighbour.id, in: $0) }) { _ in
            earlier.speakerID == later.speakerID
                ? "Combined two turns into one."
                : "Combined two turns as \(earlier.speakerLabel); reassign it if \(later.speakerLabel) was speaking."
        }
        selectedSegmentID = earlier.id
    }

    /// Replaces the words of a turn.
    public func replaceText(of segmentID: String, with text: String) {
        applyEdit({ try TranscriptSegmentEditor.replacingText(of: segmentID, with: text, in: $0) }) { _ in
            "Updated the words of this turn."
        }
    }

    /// Files one turn under another speaker this recording already has.
    public func move(segmentID: String, toSpeakerID speakerID: String) {
        applyEdit({ try TranscriptSpeakerLabelEditor.moving(segmentID: segmentID, toSpeakerID: speakerID, in: $0) }) { revised in
            let label = revised.speakers.first { $0.id == speakerID }?.labelSnapshot ?? speakerID
            return "Moved this turn to \(label)."
        }
    }

    /// Folds one recording-local speaker into another.
    public func mergeSpeaker(_ speakerID: String, into targetSpeakerID: String) {
        let sourceLabel = recordingSpeakers.first { $0.id == speakerID }?.labelSnapshot ?? speakerID
        applyEdit({ try TranscriptSpeakerLabelEditor.merging(speakerID: speakerID, into: targetSpeakerID, in: $0) }) { revised in
            let label = revised.speakers.first { $0.id == targetSpeakerID }?.labelSnapshot ?? targetSpeakerID
            return "Merged \(sourceLabel) into \(label)."
        }
        if speakerFilterID == speakerID { speakerFilterID = targetSpeakerID }
    }

    // MARK: - Undo

    public var canUndo: Bool { !(undoStacks[selectedFileID ?? ""] ?? []).isEmpty }
    public var canRedo: Bool { !(redoStacks[selectedFileID ?? ""] ?? []).isEmpty }

    /// Returns to the state before the last edit, as a new saved revision.
    public func undo() {
        guard let fileID = selectedFileID, let current = selectedTranscript,
              let previous = undoStacks[fileID]?.popLast() else { return }
        redoStacks[fileID, default: []].append(current)
        replaceSelectedTranscript(previous.asRevision(current.revision + 1))
        speakerActionMessage = TranscriptSpeakerActionMessage(text: "Undid the last edit.", isFailure: false)
    }

    public func redo() {
        guard let fileID = selectedFileID, let current = selectedTranscript,
              let next = redoStacks[fileID]?.popLast() else { return }
        undoStacks[fileID, default: []].append(current)
        replaceSelectedTranscript(next.asRevision(current.revision + 1))
        speakerActionMessage = TranscriptSpeakerActionMessage(text: "Redid the last edit.", isFailure: false)
    }

    // MARK: - Speakers

    public var speakerRows: [TranscriptSpeakerRow] {
        guard let file = selectedFile, let transcript = file.transcript else { return [] }
        var counts: [String: Int] = [:]
        for segment in transcript.segments {
            guard let speakerID = segment.speakerID else { continue }
            counts[speakerID, default: 0] += 1
        }
        return transcript.speakers.map { speaker in
            TranscriptSpeakerRow(
                speakerID: speaker.id,
                label: speaker.labelSnapshot,
                assignment: speaker.identityAssignment,
                profileID: speaker.profileID,
                segmentCount: counts[speaker.id] ?? 0,
                suggestion: file.suggestions.first { $0.speakerID == speaker.id }
            )
        }
    }

    /// Suggestions awaiting confirmation on the selected file.
    public var pendingSuggestions: [TranscriptSpeakerSuggestion] { selectedFile?.suggestions ?? [] }

    public func loadPeople() async {
        guard let directory else { return }
        do {
            people = try await directory.people()
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Could not read the speaker library: \(Self.describe(error))",
                isFailure: true
            )
        }
    }

    /// Assigns an existing person, or clears the assignment when `person` is nil.
    ///
    /// This only rewrites labels, so it produces a new transcript revision that
    /// exports immediately without rerunning recognition.
    public func assign(_ person: SpeakerPersonRef?, scope: TranscriptSpeakerScope) {
        applyRevision(scope: scope) { transcript in
            try TranscriptSpeakerLabelEditor.assigning(person: person, scope: scope, in: transcript)
        } success: {
            person.map { "Labelled as \($0.displayName)." } ?? "Cleared the saved name for this speaker."
        }
    }

    /// Creates a name-only person in the library and assigns them here.
    public func assignNewPerson(named name: String, scope: TranscriptSpeakerScope) async {
        guard let directory else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "No speaker library is connected.", isFailure: true)
            return
        }
        do {
            let person = try await directory.createPerson(named: name)
            people = try await directory.people()
            assign(person, scope: scope)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Could not add \(name): \(Self.describe(error))",
                isFailure: true
            )
        }
    }

    /// Accepts a suggested match. A person approved it, so it is recorded as a
    /// manual assignment rather than an automatic one.
    public func confirm(_ suggestion: TranscriptSpeakerSuggestion) {
        assign(suggestion.person, scope: .cluster(speakerID: suggestion.speakerID))
        guard speakerActionMessage?.isFailure != true else { return }
        removeSuggestion(forSpeakerID: suggestion.speakerID)
        speakerActionMessage = TranscriptSpeakerActionMessage(
            text: "Confirmed \(suggestion.person.displayName) for \(suggestion.speakerID).",
            isFailure: false
        )
    }

    /// Rejects a suggestion. The generic label stays and no signature is written.
    public func dismiss(_ suggestion: TranscriptSpeakerSuggestion) {
        removeSuggestion(forSpeakerID: suggestion.speakerID)
        speakerActionMessage = TranscriptSpeakerActionMessage(
            text: "Kept the generic label for \(suggestion.speakerID).",
            isFailure: false
        )
    }

    /// Applies current library names to this transcript as a new revision.
    ///
    /// Renaming a person in the library never rewrites saved transcripts on its
    /// own; this is the explicit operation that does, and exported files
    /// already on disk are left alone.
    public func refreshLabelsFromLibrary(announceUnchanged: Bool = true) async {
        guard directory != nil else { return }
        await loadPeople()
        guard let file = selectedFile, let transcript = file.transcript else { return }
        guard let refreshed = TranscriptSpeakerLabelEditor.refreshingLabels(using: people, in: transcript) else {
            if announceUnchanged {
                speakerActionMessage = TranscriptSpeakerActionMessage(text: "Labels already match the speaker library.", isFailure: false)
            }
            return
        }
        replaceSelectedTranscript(refreshed)
        speakerActionMessage = TranscriptSpeakerActionMessage(
            text: "Refreshed labels from the speaker library as revision \(refreshed.revision).",
            isFailure: false
        )
    }

    // MARK: - Remember this voice

    /// Collects the excerpts a user can confirm for enrollment of one cluster.
    public func beginRememberingVoice(speakerID: String) {
        guard let transcript = selectedTranscript else { return }
        enrollmentSpeakerID = speakerID
        enrollmentCandidates = TranscriptEnrollmentCandidates.candidates(forSpeakerID: speakerID, in: transcript)
    }

    public func cancelRememberingVoice() {
        enrollmentSpeakerID = nil
        enrollmentCandidates = []
    }

    public func setCandidate(_ segmentID: String, confirmed: Bool) {
        guard let index = enrollmentCandidates.firstIndex(where: { $0.segmentID == segmentID }) else { return }
        guard enrollmentCandidates[index].isEligible || !confirmed else { return }
        enrollmentCandidates[index].isConfirmed = confirmed
    }

    /// Seeks the retained snapshot so the user can hear an excerpt before confirming it.
    public func preview(_ candidate: TranscriptEnrollmentCandidate) {
        playback.seek(toMilliseconds: candidate.startMs)
    }

    public var confirmedEnrollmentDuration: TimeInterval {
        TranscriptEnrollmentCandidates.confirmedSpeechDuration(of: enrollmentCandidates)
    }

    /// Enrolls the confirmed excerpts for future recordings. Separate from
    /// labelling: this is the only path that writes a voice signature.
    public func rememberVoice(target: SpeakerEnrollmentTarget, retainClips: Bool = false) async {
        guard let directory else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "No speaker library is connected.", isFailure: true)
            return
        }
        guard let file = selectedFile, let transcript = file.transcript else { return }
        let excerpts = TranscriptEnrollmentCandidates.excerpts(from: enrollmentCandidates)
        guard !excerpts.isEmpty else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "Confirm at least one clean excerpt first.", isFailure: true)
            return
        }

        isEnrolling = true
        defer { isEnrolling = false }
        do {
            let result = try await directory.enroll(
                SpeakerEnrollmentRequest.transcriptSelection(
                    sourceID: transcript.transcriptID,
                    audioFileURL: file.sourceSnapshotURL,
                    target: target,
                    excerpts: excerpts,
                    confirmation: .userConfirmedExcerpts,
                    retainClips: retainClips
                )
            )
            people = (try? await directory.people()) ?? people
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Remembered \(result.profile.displayName) from \(result.selectedExcerpts.count) excerpt(s), \(Int(result.usableSpeechDuration.rounded()))s of speech.",
                isFailure: false
            )
            cancelRememberingVoice()
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Could not remember this voice: \(Self.describe(error))",
                isFailure: true
            )
        }
    }

    // MARK: - Private

    private func applyRevision(
        scope: TranscriptSpeakerScope,
        _ edit: (CanonicalTranscript) throws -> CanonicalTranscript,
        success: () -> String
    ) {
        let message = success()
        applyEdit(edit) { _ in message }
    }

    /// Runs one edit against the selected transcript and records the result.
    /// An edit that returns the transcript unchanged is not a revision and
    /// does not enter the undo history.
    private func applyEdit(
        _ edit: (CanonicalTranscript) throws -> CanonicalTranscript,
        success: (CanonicalTranscript) -> String
    ) {
        guard let fileID = selectedFileID, let transcript = selectedTranscript else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "This file has no transcript to edit.", isFailure: true)
            return
        }
        do {
            let revised = try edit(transcript)
            guard revised != transcript else { return }
            undoStacks[fileID, default: []].append(transcript)
            redoStacks[fileID] = []
            replaceSelectedTranscript(revised)
            speakerActionMessage = TranscriptSpeakerActionMessage(text: success(revised), isFailure: false)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: Self.describe(error), isFailure: true)
        }
    }

    /// Records a new revision in memory and, when the host attached a store, on
    /// disk. A revision that cannot be persisted is still shown, and the failure
    /// is reported rather than swallowed: the words are unchanged either way.
    private func replaceSelectedTranscript(_ transcript: CanonicalTranscript) {
        guard let index = files.firstIndex(where: { $0.id == selectedFileID }) else { return }
        let file = files[index].replacingTranscript(transcript)
        files[index] = file
        do {
            try revisionStore?.save(transcript, forFileID: file.id)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Revision \(transcript.revision) is shown here but could not be saved: \(Self.describe(error))",
                isFailure: true
            )
        }
    }

    private func removeSuggestion(forSpeakerID speakerID: String) {
        guard let index = files.firstIndex(where: { $0.id == selectedFileID }) else { return }
        files[index].suggestions.removeAll { $0.speakerID == speakerID }
    }

    private func selectFileIfNeeded() {
        cancelRememberingVoice()
        stopPlayback()
        speakerFilterID = nil
        playheadMilliseconds = 0
        guard let file = selectedFile else {
            selectedSegmentID = nil
            return
        }
        playback.load(sourceSnapshotURL: file.sourceSnapshotURL)
        selectedSegmentID = nil
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
