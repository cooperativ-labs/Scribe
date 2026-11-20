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
        didSet {
            // Leaving a meeting writes its notes now rather than after the
            // quiet period.
            if oldValue != selectedFileID, let oldValue, let draftID = files.first(where: { $0.id == oldValue })?.draft?.id {
                flushNotes(draftID: draftID)
            }
            selectFileIfNeeded()
        }
    }
    public private(set) var selectedSegmentID: TranscriptSegment.ID?
    public let toastCenter = TranscriptToastCenter()
    public private(set) var exportOutcomes: [TranscriptExportOutcome] = [] {
        didSet { if !exportOutcomes.isEmpty { announceExportOutcomes() } }
    }
    public private(set) var exportMessage: TranscriptExportMessage? {
        didSet {
            if let exportMessage {
                toastCenter.post(exportMessage.text, kind: exportMessage.isFailure ? .failure : .result)
            }
        }
    }

    /// People available to the speaker picker, refreshed from the library.
    public private(set) var people: [SpeakerPersonRef] = []
    public private(set) var speakerActionMessage: TranscriptSpeakerActionMessage? {
        didSet {
            if let speakerActionMessage {
                toastCenter.post(speakerActionMessage.text,
                                 kind: speakerActionMessage.isFailure ? .failure : .result,
                                 action: speakerActionMessage.isFailure ? nil : nextToastAction)
            }
            nextToastAction = nil
        }
    }
    @ObservationIgnored private var nextToastAction: TranscriptToast.Action?
    /// Speaker-count reprocess confirmation and progress sheet, when one is open.
    public private(set) var reprocessSession: TranscriptReprocessSession?
    /// Candidate excerpts for the in-progress "Remember this voice" action.
    public private(set) var enrollmentCandidates: [TranscriptEnrollmentCandidate] = []
    public private(set) var enrollmentSpeakerID: String?
    public private(set) var isEnrolling = false
    public private(set) var previewingCandidateID: String?
    @ObservationIgnored private var previewEndMilliseconds: Int?

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
    @ObservationIgnored private let clipboard: any TranscriptClipboardWriting
    @ObservationIgnored private let directory: (any TranscriptSpeakerDirectory)?
    @ObservationIgnored private let revisionStore: (any TranscriptRevisionStoring)?
    @ObservationIgnored private let fileDeleter: (any TranscriptFileDeleting)?
    @ObservationIgnored private let recordingCombiner: (any TranscriptRecordingCombining)?
    @ObservationIgnored private let fileImporter: (any TranscriptFileImporting)?
    @ObservationIgnored private let pastedTranscriptImporter: (any PastedTranscriptImporting)?
    @ObservationIgnored private let reprocessor: (any TranscriptReprocessing)?
    @ObservationIgnored private let retranscriber: (any TranscriptRetranscribing)?
    /// Hands a finished transcript to a coding agent. Absent in a build with no
    /// agent host, which hides the action rather than offering a dead end.
    @ObservationIgnored let agentDispatcher: (any TranscriptAgentDispatching)?
    /// What sending remembers: last agent, models, efforts, prompts per folder.
    @ObservationIgnored let agentPreferences: TranscriptAgentPreferences
    /// Opens the vocabulary editor in the host's Settings window. Absent in a
    /// build with no settings surface — the toolbar then hides the button
    /// rather than offering a route that goes nowhere.
    @ObservationIgnored private let openVocabularySettings: (@MainActor () -> Void)?
    /// Edits meeting drafts by ID. Absent when the host keeps no drafts.
    @ObservationIgnored let draftEditor: (any MeetingDraftEditing)?
    /// Queues, cancels and confirms a meeting's "Send after processing".
    /// Absent where nothing can fire a queued send, which hides the control.
    @ObservationIgnored let sendController: (any MeetingSendControlling)?

    /// The outcome of the last drop, shown in the sidebar until the next one.
    public private(set) var importMessage: TranscriptSpeakerActionMessage?
    /// True while dropped files are being probed and queued.
    public private(set) var isImporting = false
    @ObservationIgnored private var importToastID: UUID?

    /// What the host found for the handoff tray: installed agents and
    /// connected folders. Machine facts, shared by every tray; nil until the
    /// host has been asked.
    public internal(set) var agentEnvironment: TranscriptAgentEnvironment?
    /// Handoff settings of rows with no meeting draft (imports, pasted
    /// transcripts), each seeded from the remembered preferences the first
    /// time its tray is shown and kept while the window is open. A meeting's
    /// own settings live in its draft.
    var transcriptHandoffs: [TranscriptReviewFile.ID: MeetingHandoffSettings] = [:]
    /// Each tray's manual send, by what it is bound to.
    public internal(set) var handoffStatuses: [AgentHandoffTarget: AgentHandoffSendStatus] = [:]
    /// Bumped when a draft's handoff settings are written from here, so
    /// views reading them through the draft editor redraw.
    var handoffRevision = 0
    /// Bumped when a draft's notes are written from here, so every editor
    /// showing that draft (window and floating panel) picks the edit up.
    /// Read only by `notesContent(draftID:)`, which only the editors' own
    /// small views call, so a keystroke never redraws a whole transcript.
    var notesRevision = 0

    public init(
        files: [TranscriptReviewFile],
        selectedFileID: TranscriptReviewFile.ID? = nil,
        playback: any TranscriptPlaybackSeeking,
        exportWriter: any TranscriptExportWriting = FileTranscriptExportWriter(),
        clipboard: any TranscriptClipboardWriting = SystemTranscriptClipboard(),
        directory: (any TranscriptSpeakerDirectory)? = nil,
        revisionStore: (any TranscriptRevisionStoring)? = nil,
        fileDeleter: (any TranscriptFileDeleting)? = nil,
        recordingCombiner: (any TranscriptRecordingCombining)? = nil,
        fileImporter: (any TranscriptFileImporting)? = nil,
        pastedTranscriptImporter: (any PastedTranscriptImporting)? = nil,
        reprocessor: (any TranscriptReprocessing)? = nil,
        retranscriber: (any TranscriptRetranscribing)? = nil,
        agentDispatcher: (any TranscriptAgentDispatching)? = nil,
        agentPreferences: TranscriptAgentPreferences = TranscriptAgentPreferences(),
        openVocabularySettings: (@MainActor () -> Void)? = nil,
        draftEditor: (any MeetingDraftEditing)? = nil,
        sendController: (any MeetingSendControlling)? = nil
    ) {
        self.files = files
        self.draftEditor = draftEditor
        self.sendController = sendController
        self.selectedFileID = selectedFileID ?? files.first?.id
        self.playback = playback
        self.exportWriter = exportWriter
        self.clipboard = clipboard
        self.directory = directory
        self.revisionStore = revisionStore
        self.fileDeleter = fileDeleter
        self.recordingCombiner = recordingCombiner
        self.fileImporter = fileImporter
        self.pastedTranscriptImporter = pastedTranscriptImporter
        self.reprocessor = reprocessor
        self.retranscriber = retranscriber
        self.agentDispatcher = agentDispatcher
        self.agentPreferences = agentPreferences
        self.openVocabularySettings = openVocabularySettings
        selectFileIfNeeded()
        playback.setPlaybackObserver { [weak self] event in self?.handle(event) }
    }

    /// Whether the review window can send someone to the vocabulary editor.
    public var canOpenVocabularySettings: Bool { openVocabularySettings != nil }

    public var canImportPastedTranscript: Bool { pastedTranscriptImporter != nil }

    /// Commits to disk before changing selection; a failed import leaves the list intact.
    public func importPastedTranscript(_ text: String, format: TranscriptImportFormat, title: String) throws {
        guard let pastedTranscriptImporter else {
            throw PastedTranscriptImportError(message: "Transcript import is unavailable.")
        }
        let file = try pastedTranscriptImporter.importTranscript(text, format: format, title: title)
        files.insert(file, at: 0)
        selectedFileID = file.id
        toastCenter.post("Transcript imported.", kind: .result)
    }

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
        self.files = incoming.map { incomingFile in
            var file = incomingFile
            guard let existing = edited[file.id] else { return file }
            // A row keyed by its meeting draft keeps its key when a rerun
            // replaces the run behind it; the undo history belonged to the old
            // run's revisions and must not be replayed onto the new one.
            if existing.runID != file.runID {
                undoStacks[file.id] = nil
                redoStacks[file.id] = nil
                return file
            }
            if let existingDraft = existing.draft, let incomingDraft = file.draft,
               existingDraft.revision > incomingDraft.revision {
                file = file.replacingDraft(existingDraft)
            }
            guard let existingTranscript = existing.transcript,
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

    public var chronologicalSegments: [TranscriptSegment] { order.segments }

    /// Reading paragraphs derived from the current canonical segments.
    public var chronologicalParagraphs: [TranscriptParagraph] { order.paragraphs }

    /// The selected transcript in time order, worked out once per version of
    /// its turns. Every list row asks for it (its neighbours, its paragraph,
    /// which source is playing) and paragraph rows redraw on each playback
    /// tick, so sorting and grouping two thousand turns per question kept the
    /// main thread busy. Reading `selectedTranscript` here keeps observation
    /// exactly as before; only the derived arrays are remembered.
    private var order: TranscriptOrder {
        let source = selectedTranscript?.segments ?? []
        if let cached = orderCache, cached.source == source { return cached }
        let order = TranscriptOrder(source: source)
        orderCache = order
        return order
    }

    @ObservationIgnored private var orderCache: TranscriptOrder?

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

    /// The recording's length for the header chip: minutes and seconds, with
    /// hours only when the source runs past an hour.
    public var lengthText: String? {
        guard let transcript = selectedTranscript else { return nil }
        return TranscriptReviewFile.lengthLabel(milliseconds: transcript.source.durationMs)
    }

    public var speakerCountText: String? {
        guard let speakers = selectedTranscript?.speakers.count else { return nil }
        return "\(speakers) speaker\(speakers == 1 ? "" : "s")"
    }

    /// Shows only the turns that need review: the header's "N to review" chip.
    public func showTurnsNeedingReview() {
        reviewFilter = .needsReview
    }

    /// Case- and accent-insensitive comparison key for search.
    public static func normalizedSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var languageDescription: String? {
        guard let transcript = selectedTranscript else { return nil }
        return "Language: \(transcript.language) (\(Self.provenance(of: transcript.languageSource)))"
    }

    /// The language by name ("English"), falling back to the stored code when
    /// the system has no name for it.
    public var languageName: String? {
        guard let transcript = selectedTranscript else { return nil }
        let code = transcript.language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Where the language came from, for the language chip's tooltip.
    public var languageHelp: String? {
        guard let transcript = selectedTranscript else { return nil }
        let origin: String = switch transcript.languageSource {
        case .detected: "Detected from the recording"
        case .userProvided: "Chosen before transcription"
        case .unknown: "Source unknown"
        }
        return "\(origin) (\(transcript.language))"
    }

    private static func provenance(of source: TranscriptLanguageSource) -> String {
        switch source {
        case .detected: "detected"
        case .userProvided: "user-provided"
        case .unknown: "unknown"
        }
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
        let order = order
        return order.paragraphIndexBySegmentID[segmentID].map { order.paragraphs[$0] }
    }

    /// The canonical segment a paragraph row should act on: the selected source
    /// when it belongs to the paragraph, otherwise the source covering the play
    /// head, otherwise the first source.
    public func primarySegment(for paragraph: TranscriptParagraph) -> TranscriptSegment? {
        let order = order
        let sources = paragraph.sourceSegmentIDs.compactMap { order.segmentIndexByID[$0] }.sorted().map { order.segments[$0] }
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
        guard canPlayAudio else { return }
        previewingCandidateID = nil
        previewEndMilliseconds = nil
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
        guard canPlayAudio else { return }
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
        previewingCandidateID = nil
        previewEndMilliseconds = nil
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
            if let previewEndMilliseconds, milliseconds >= previewEndMilliseconds {
                stopPlayback()
                return
            }
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
        guard !file.isPlaceholder else { return false }
        switch file.jobState {
        case .recording, .ready, .queued, .processing: return false
        case .complete, .completeWithWarnings, .noSpeech, .failed: return true
        }
    }

    /// Removes the file from the host store and the list. When it was the one
    /// on screen, playback stops and the selection moves to its neighbour.
    public func delete(fileID: TranscriptReviewFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == fileID }), canDelete(files[index]) else { return }
        let file = files[index]
        guard let runID = file.runID else { return }
        do {
            try fileDeleter?.delete(fileID: runID)
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
        // The meeting is gone, so its draft record goes with it.
        if let draft = file.draft, let draftEditor {
            Task { try? await draftEditor.deleteDraft(draftID: draft.id) }
        }
    }

    /// Whether the sidebar offers to delete only the recording. Same rule as
    /// deleting the file, and there must still be a recording to delete.
    public func canDeleteAudio(_ file: TranscriptReviewFile) -> Bool {
        file.hasAudio && canDelete(file)
    }

    /// Removes the recording and keeps the transcript in the list. Playback
    /// stops first when this is the file on screen, so the player lets go of
    /// the source before it disappears.
    public func deleteAudio(fileID: TranscriptReviewFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == fileID }), canDeleteAudio(files[index]) else { return }
        let file = files[index]
        if selectedFileID == fileID {
            stopPlayback()
            cancelRememberingVoice()
        }
        guard let runID = file.runID else { return }
        do {
            try fileDeleter?.deleteAudio(fileID: runID)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(
                text: "Could not delete the audio for \(file.filename): \(Self.describe(error))",
                isFailure: true
            )
            return
        }
        files[index] = file.removingAudio()
    }

    // MARK: - Combining

    /// True while two recordings are being joined.
    public private(set) var isCombining = false

    /// Whether this file can take part in combining: a finished transcript,
    /// its recording still here, and nothing of it still running.
    public func canCombine(_ file: TranscriptReviewFile) -> Bool {
        guard recordingCombiner != nil, file.transcript != nil, file.hasAudio else { return false }
        // A send that is queued, held, claimed or of unknown outcome must be
        // resolved first (decision 12).
        if file.draft?.sendBlocksCombine == true { return false }
        return canDelete(file)
    }

    /// The files `file` could be combined with, nearest in time first, since
    /// the two halves of a cut-off call were made minutes apart.
    public func combineCandidates(for file: TranscriptReviewFile) -> [TranscriptReviewFile] {
        guard canCombine(file) else { return [] }
        let reference = file.createdDate
        return files
            .filter { $0.id != file.id && canCombine($0) }
            .sorted { lhs, rhs in
                guard let reference, let left = lhs.createdDate, let right = rhs.createdDate else {
                    return (lhs.createdDate ?? .distantPast) > (rhs.createdDate ?? .distantPast)
                }
                return abs(left.timeIntervalSince(reference)) < abs(right.timeIntervalSince(reference))
            }
    }

    /// Appends the second recording to the first and replaces both files with
    /// the combined one, which is then selected. This cannot be undone: the
    /// two originals are removed from the store.
    public func combine(firstFileID: TranscriptReviewFile.ID, secondFileID: TranscriptReviewFile.ID) async {
        guard let recordingCombiner, !isCombining, firstFileID != secondFileID,
              let first = files.first(where: { $0.id == firstFileID }), canCombine(first),
              let second = files.first(where: { $0.id == secondFileID }), canCombine(second)
        else { return }
        if selectedFileID == firstFileID || selectedFileID == secondFileID {
            stopPlayback()
            cancelRememberingVoice()
        }
        isCombining = true
        let toastID = toastCenter.post("Combining \u{201C}\(first.displayName)\u{201D} and \u{201C}\(second.displayName)\u{201D}…", kind: .progress)
        defer { isCombining = false }
        var combined: TranscriptReviewFile
        guard let firstRunID = first.runID, let secondRunID = second.runID else { return }
        // Both meetings' notes are written before the combine reads them; a
        // send under way on either refuses it.
        let draftIDs = [first.draft?.id, second.draft?.id].compactMap { $0 }
        if let draftEditor, !draftIDs.isEmpty, let reason = await draftEditor.prepareForCombine(draftIDs: draftIDs) {
            toastCenter.finish(toastID, text: "Could not combine the recordings: \(reason)", failure: true)
            return
        }
        do {
            combined = try await recordingCombiner.combine(firstFileID: firstRunID, secondFileID: secondRunID)
        } catch {
            toastCenter.finish(toastID, text: "Could not combine the recordings: \(Self.describe(error))", failure: true)
            return
        }
        // The combined meeting keeps the first recording's row (else the
        // second's), so it stays selected under the same key.
        let owner = first.draft ?? second.draft
        if let owner { combined = combined.keyed(byDraft: owner) }
        let insertAt = files.firstIndex { $0.id == firstFileID || $0.id == secondFileID } ?? 0
        files.removeAll { $0.id == firstFileID || $0.id == secondFileID }
        files.insert(combined, at: min(insertAt, files.count))
        undoStacks[firstFileID] = nil
        undoStacks[secondFileID] = nil
        redoStacks[firstFileID] = nil
        redoStacks[secondFileID] = nil
        selectedFileID = combined.id
        toastCenter.finish(toastID, text: "Combined into \u{201C}\(combined.displayName)\u{201D}.", failure: false)
        // Both meetings' notes now live in the combined one. The owning row
        // loses its handoff settings; the other draft's record goes.
        if let draftEditor, !draftIDs.isEmpty {
            await draftEditor.finishCombine(ownerDraftID: owner?.id, absorbedDraftIDs: draftIDs)
        }
    }

    /// Whether the selected file still has a recording to play.
    public var canPlayAudio: Bool { selectedFile?.hasAudio ?? false }

    // MARK: - Importing

    /// Whether the sidebar accepts dropped files at all. Without a host
    /// importer there is nowhere to queue them, so the drop is refused up
    /// front rather than accepted and silently lost.
    public var canImportFiles: Bool { fileImporter != nil }

    /// Whether the toolbar offers speaker-count reprocess. An in-flight job or
    /// an open reprocess sheet blocks another queue until that one settles,
    /// and a file whose recording was deleted has no audio to diarize.
    public var canReprocess: Bool {
        guard reprocessor != nil, let file = selectedFile, !file.isPlaceholder, file.hasAudio, reprocessSession == nil else { return false }
        switch file.jobState {
        case .recording, .ready, .queued, .processing: return false
        case .complete, .completeWithWarnings, .noSpeech, .failed: return true
        }
    }

    /// Whether the sidebar offers to retranscribe this file. A job still in
    /// flight is left alone: queuing another full run of the same source while
    /// its first pass is writing checkpoints is more confusing than useful.
    /// Without its recording there is nothing to run again.
    public func canRetranscribe(_ file: TranscriptReviewFile) -> Bool {
        guard retranscriber != nil, !file.isPlaceholder, file.hasAudio else { return false }
        switch file.jobState {
        case .recording, .ready, .queued, .processing: return false
        case .complete, .completeWithWarnings, .noSpeech, .failed: return true
        }
    }

    /// Opens the confirmation sheet for a chosen speaker count. The run is not
    /// queued until the person confirms on that screen.
    public func presentReprocessConfirmation(speakerCount: TranscriptionSpeakerCount) {
        guard canReprocess, let file = selectedFile else { return }
        guard let runID = file.runID else { return }
        reprocessSession = TranscriptReprocessSession(
            fileID: runID,
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
        guard let retranscriber, let file = files.first(where: { $0.id == fileID }), canRetranscribe(file),
              let runID = file.runID else { return }
        let outcome = await retranscriber.retranscribe(fileID: runID)
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
        let toastID = toastCenter.post("Queuing \(urls.count) \(urls.count == 1 ? "file" : "files")…", kind: .progress)
        importToastID = toastID
        defer { isImporting = false }
        let outcome = await fileImporter.importFiles(at: urls)
        importMessage = TranscriptSpeakerActionMessage(text: outcome.summary, isFailure: outcome.isFailure)
        toastCenter.finish(toastID, text: outcome.summary, failure: outcome.isFailure)
    }

    public func dismissImportMessage() {
        importMessage = nil
        if let importToastID { toastCenter.dismiss(importToastID) }
        importToastID = nil
    }

    private func announceExportOutcomes() {
        let successes = exportOutcomes.filter(\.succeeded)
        let failures = exportOutcomes.filter { !$0.succeeded }
        let text: String
        if failures.isEmpty {
            let formats = successes.map { $0.format.rawValue.uppercased() }.joined(separator: ", ")
            text = "Exported \(formats)."
        } else if successes.isEmpty {
            text = failures.count == 1
                ? "\(failures[0].format.rawValue.uppercased()) export failed: \(failures[0].errorMessage ?? "Unknown error")"
                : "\(failures.count) exports failed."
        } else {
            text = "Exported \(successes.count) format\(successes.count == 1 ? "" : "s"); \(failures.count) failed."
        }
        let finderURL = successes.first?.destinationURL
        if let warning = exportNotesWarning, !successes.isEmpty {
            toastCenter.post(text + " " + warning, kind: .failure, action: finderURL.map { .showInFinder($0) })
            return
        }
        toastCenter.post(text, kind: failures.isEmpty ? .result : .failure,
                         action: finderURL.map { .showInFinder($0) })
    }

    /// Set while announcing an export whose meeting notes could not be read
    /// and were left out, so the toast says so instead of reporting success.
    @ObservationIgnored private var exportNotesWarning: String?

    /// The notes an export of `file` carries: none for imports and pasted
    /// transcripts (they have no notes), else what the row shows. Notes that
    /// cannot be read are left out with a warning rather than blocking the
    /// transcript's export.
    func exportNotes(for file: TranscriptReviewFile?) -> (notes: [TranscriptExportNote], warning: String?) {
        guard let draft = file?.draft, let draftEditor else { return ([], nil) }
        switch draftEditor.exportNotes(draftID: draft.id) {
        case .success(let notes): return (notes, nil)
        case .failure(let error): return ([], "Meeting notes were left out: \(error.message)")
        }
    }

    /// Exports each requested format separately so an SRT failure does not lose valid TXT/JSON.
    public func export(_ formats: Set<TranscriptExportFormat>, to directoryURL: URL, basename: String? = nil) {
        exportMessage = nil
        exportNotesWarning = nil
        guard let transcript = selectedTranscript else {
            exportOutcomes = formats.map {
                TranscriptExportOutcome(format: $0, destinationURL: nil, errorMessage: "This file has no completed transcript to export.")
            }
            return
        }
        let name = basename ?? FileTranscriptExportWriter.basename(for: transcript)
        let notes = exportNotes(for: selectedFile)
        exportNotesWarning = notes.warning
        exportOutcomes = exportWriter.write(transcript, notes: notes.notes, formats: formats, to: directoryURL, basename: name)
    }

    /// Writes one format to the exact file the Save panel chose, including a renamed file.
    public func export(_ format: TranscriptExportFormat, toFile fileURL: URL) {
        exportMessage = nil
        exportNotesWarning = nil
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
        let notes = exportNotes(for: selectedFile)
        // SRT carries no notes, so unreadable notes change nothing about it.
        exportNotesWarning = format == .subtitles ? nil : notes.warning
        exportOutcomes = [exportWriter.write(transcript, notes: notes.notes, format: format, toFile: fileURL)]
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

    /// Copies the same schema-backed Knowledgebase document as the file export,
    /// after bringing any current speaker-library labels into the revision.
    public func copyKnowledgebaseToClipboard() async {
        exportMessage = nil
        await refreshLabelsFromLibrary(announceUnchanged: false)
        guard let transcript = selectedTranscript else {
            exportMessage = TranscriptExportMessage(
                text: "This file has no completed transcript to copy.",
                isFailure: true
            )
            return
        }

        do {
            let notes = exportNotes(for: selectedFile)
            let document = try TranscriptExporter.knowledgebaseJSON(transcript, notes: notes.notes)
            if clipboard.write(document) {
                exportMessage = TranscriptExportMessage(
                    text: notes.warning.map { "Copied Knowledgebase JSON to the clipboard. \($0)" }
                        ?? "Copied Knowledgebase JSON to the clipboard.",
                    isFailure: notes.warning != nil
                )
            } else {
                exportMessage = TranscriptExportMessage(
                    text: "Could not copy Knowledgebase JSON to the clipboard.",
                    isFailure: true
                )
            }
        } catch {
            exportMessage = TranscriptExportMessage(
                text: "Could not copy Knowledgebase JSON: \(Self.describe(error))",
                isFailure: true
            )
        }
    }

    // MARK: - Naming

    /// Gives the transcript a name of its own, or clears it back to the source
    /// filename with nil. Like every edit, this is a saved revision.
    public func rename(to title: String?) {
        guard let selectedFileID else { return }
        rename(fileID: selectedFileID, to: title)
    }

    /// Renames one row, named by its key rather than by whatever is selected
    /// when the work finishes. A transcript gets a renamed revision now; a
    /// meeting draft records the title too, so a placeholder can be named
    /// while recording and a later run opens under the same name.
    public func rename(fileID: TranscriptReviewFile.ID, to title: String?) {
        guard let file = files.first(where: { $0.id == fileID }) else { return }
        if file.transcript != nil {
            let before = file.transcript
            applyEdit(toFileID: fileID, { try TranscriptSegmentEditor.renaming(to: title, in: $0) }) { revised in
                revised.title.map { "Renamed to \u{201C}\($0)\u{201D}." } ?? "Cleared the name; the transcript goes by its source filename."
            }
            // A refused name (a blank one) is not passed on to the draft.
            if files.first(where: { $0.id == fileID })?.transcript == before, before?.title != title { return }
        } else if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: Self.describe(TranscriptSegmentEditError.emptyTitle), isFailure: true)
            return
        }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft = file.draft, let draftEditor, draft.title != title else { return }
        let draftID = draft.id
        let revision = draft.revision
        let previousTitle = draft.title
        Task { [weak self] in
            do {
                let summary = try await draftEditor.setTitle(draftID: draftID, title: title, basedOnRevision: revision, previousTitle: previousTitle)
                self?.applyDraftSummary(summary, toFileID: fileID)
                if file.transcript == nil {
                    self?.speakerActionMessage = TranscriptSpeakerActionMessage(
                        text: title.map { "Renamed to \u{201C}\($0)\u{201D}. The transcript will use this name." }
                            ?? "Cleared the name; the meeting goes by its default name.",
                        isFailure: false
                    )
                }
            } catch {
                self?.speakerActionMessage = TranscriptSpeakerActionMessage(text: "Could not rename: \(Self.describe(error))", isFailure: true)
            }
        }
    }

    // MARK: - Meeting notes

    /// The notes a row shows, or nil for rows that have none: imports and
    /// pasted transcripts get no notes pane (decision 11).
    public func notesContent(for file: TranscriptReviewFile) -> MeetingNotesContent? {
        guard let draft = file.draft else { return nil }
        return notesContent(draftID: draft.id)
    }

    /// A draft's notes, read so that a view showing them redraws when any
    /// editor changes them: the Transcripts window and the floating notes
    /// panel edit the same draft through this model, and each shows the
    /// other's edits as they are made.
    public func notesContent(draftID: UUID) -> MeetingNotesContent? {
        _ = notesRevision
        return draftEditor?.notes(draftID: draftID)
    }

    /// Replaces the notes of the draft named, never "the selected one": the
    /// editor captured the ID when it was given the notes.
    public func setNotes(draftID: UUID, notes: [MeetingNote]) {
        guard let draftEditor else { return }
        draftEditor.setNotes(draftID: draftID, notes: notes)
        notesRevision &+= 1
    }

    /// An edit to the draft that is not written yet, or whose write failed.
    public func hasUnsavedEdits(draftID: UUID) -> Bool {
        draftEditor?.hasUnsavedEdits(draftID: draftID) ?? false
    }

    /// The time a note written now in this draft is stamped with.
    public func noteClock(draftID: UUID) -> Int? {
        draftEditor?.noteClock(draftID: draftID)
    }

    /// Writes the draft's notes now: on leaving it or closing the window.
    public func flushNotes(draftID: UUID) {
        guard let draftEditor else { return }
        Task { await draftEditor.flushNotes(draftID: draftID) }
    }

    /// Whether a note's stamp can move playback there: the selected row has
    /// a transcript and its recording, and the time is inside the recording.
    public func canSeek(toNoteOffset milliseconds: Int?, in file: TranscriptReviewFile) -> Bool {
        guard let milliseconds, milliseconds >= 0, file.id == selectedFileID,
              file.transcript != nil, file.hasAudio else { return false }
        let duration = file.transcript?.source.durationMs ?? 0
        return milliseconds <= duration
    }

    /// Moves playback to a note's time and highlights the turn nearest it,
    /// without starting sound.
    public func seek(toNoteOffset milliseconds: Int) {
        guard let file = selectedFile, canSeek(toNoteOffset: milliseconds, in: file) else { return }
        playheadMilliseconds = milliseconds
        playback.seek(toMilliseconds: milliseconds)
        guard let nearest = Self.nearestSegment(to: milliseconds, in: chronologicalSegments) else { return }
        selectedSegmentID = nearest.id
        if playingSegmentID != nil { playingSegmentID = nearest.id }
    }

    /// The turn a note at `milliseconds` refers to: one that spans the time,
    /// else whichever starts or ends closest to it.
    public static func nearestSegment(to milliseconds: Int, in segments: [TranscriptSegment]) -> TranscriptSegment? {
        if let containing = segments.last(where: { $0.startMs <= milliseconds && milliseconds <= $0.endMs }) {
            return containing
        }
        return segments.min { lhs, rhs in
            distance(milliseconds, lhs) < distance(milliseconds, rhs)
        }
    }

    private static func distance(_ milliseconds: Int, _ segment: TranscriptSegment) -> Int {
        milliseconds < segment.startMs ? segment.startMs - milliseconds : milliseconds - segment.endMs
    }

    // MARK: - Meeting drafts

    /// Retries writing a draft whose last save failed.
    public func retrySavingDraft(fileID: TranscriptReviewFile.ID) {
        guard let draft = files.first(where: { $0.id == fileID })?.draft, let draftEditor else { return }
        let draftID = draft.id
        Task { [weak self] in
            let summary = await draftEditor.retrySave(draftID: draftID)
            self?.applyDraftSummary(summary, toFileID: fileID)
        }
    }

    /// Whether the row offers "Delete Draft": a placeholder or notes-only row
    /// that is not recording. A draft with a run is deleted with its transcript.
    public func canDeleteDraft(_ file: TranscriptReviewFile) -> Bool {
        draftEditor != nil && file.isPlaceholder && (file.draft?.canDeleteDraft ?? false)
    }

    /// Removes a placeholder's draft, its title and its notes.
    public func deleteDraft(fileID: TranscriptReviewFile.ID) async {
        guard let index = files.firstIndex(where: { $0.id == fileID }), canDeleteDraft(files[index]),
              let draft = files[index].draft, let draftEditor else { return }
        let name = files[index].displayName
        do {
            try await draftEditor.deleteDraft(draftID: draft.id)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "Could not delete \(name): \(Self.describe(error))", isFailure: true)
            return
        }
        guard let current = files.firstIndex(where: { $0.id == fileID }) else { return }
        files.remove(at: current)
        if selectedFileID == fileID {
            let neighbour = files.indices.contains(current) ? files[current] : files.last
            selectedFileID = neighbour?.id
        }
    }

    /// Hands a finished recording that was not sent automatically to transcription.
    public func transcribeDraftNow(fileID: TranscriptReviewFile.ID) async {
        guard let draft = files.first(where: { $0.id == fileID })?.draft, draft.canTranscribeNow, let draftEditor else { return }
        if let failure = await draftEditor.transcribeNow(draftID: draft.id) {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: failure, isFailure: true)
        }
    }

    private func applyDraftSummary(_ summary: MeetingDraftSummary?, toFileID fileID: TranscriptReviewFile.ID) {
        guard let summary, let index = files.firstIndex(where: { $0.id == fileID }),
              files[index].draft?.id == summary.id,
              (files[index].draft?.revision ?? 0) <= summary.revision else { return }
        files[index] = files[index].replacingDraft(summary)
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
        let order = order
        guard let index = order.segmentIndexByID[segmentID], index + 1 < order.segments.count else { return nil }
        return order.segments[index + 1]
    }

    /// The turn before this one in time, if any.
    public func segment(before segmentID: String) -> TranscriptSegment? {
        let order = order
        guard let index = order.segmentIndexByID[segmentID], index > 0 else { return nil }
        return order.segments[index - 1]
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
        replaceSelectedTranscript(previous.replacing(revision: current.revision + 1))
        nextToastAction = .redo
        speakerActionMessage = TranscriptSpeakerActionMessage(text: "Undid the last edit.", isFailure: false)
    }

    public func redo() {
        guard let fileID = selectedFileID, let current = selectedTranscript,
              let next = redoStacks[fileID]?.popLast() else { return }
        undoStacks[fileID, default: []].append(current)
        replaceSelectedTranscript(next.replacing(revision: current.revision + 1))
        nextToastAction = .undo
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
                suggestion: file.suggestions.first {
                    $0.speakerID == speaker.id && ((speaker.identityAssignment == .unmatched && $0.appliedAutomatically != true) ||
                        (speaker.identityAssignment == .automatic && $0.person.profileID.uuidString == speaker.profileID))
                }
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
        let legacySuggestionID: String? = {
            guard case let .cluster(speakerID) = scope,
                  selectedTranscript?.speakers.first(where: { $0.id == speakerID })?.identityAssignment == .unmatched else { return nil }
            return speakerID
        }()
        applyRevision(scope: scope) { transcript in
            try TranscriptSpeakerLabelEditor.assigning(person: person, scope: scope, in: transcript)
        } success: {
            person.map { "Labelled as \($0.displayName)." } ?? "Cleared the saved name for this speaker."
        }
        if speakerActionMessage?.isFailure == false, let legacySuggestionID {
            removeSuggestion(forSpeakerID: legacySuggestionID)
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
        guard canPlayAudio, let transcript = selectedTranscript else { return }
        enrollmentSpeakerID = speakerID
        enrollmentCandidates = TranscriptEnrollmentCandidates.candidates(forSpeakerID: speakerID, in: transcript)
    }

    public func cancelRememberingVoice() {
        if previewingCandidateID != nil { stopPlayback() }
        enrollmentSpeakerID = nil
        enrollmentCandidates = []
    }

    public func setCandidate(_ segmentID: String, confirmed: Bool) {
        guard let index = enrollmentCandidates.firstIndex(where: { $0.segmentID == segmentID }) else { return }
        guard enrollmentCandidates[index].isEligible || !confirmed else { return }
        enrollmentCandidates[index].isConfirmed = confirmed
    }

    /// Plays only the chosen excerpt from the retained snapshot.
    public func preview(_ candidate: TranscriptEnrollmentCandidate) {
        if previewingCandidateID == candidate.segmentID {
            stopPlayback()
            return
        }
        guard let segment = chronologicalSegments.first(where: { $0.id == candidate.segmentID }) else { return }
        play(segment: segment)
        guard isPlaying else { return }
        previewingCandidateID = candidate.segmentID
        previewEndMilliseconds = candidate.endMs
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
        guard let fileID = selectedFileID else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "This file has no transcript to edit.", isFailure: true)
            return
        }
        applyEdit(toFileID: fileID, edit, success: success)
    }

    private func applyEdit(
        toFileID fileID: TranscriptReviewFile.ID,
        _ edit: (CanonicalTranscript) throws -> CanonicalTranscript,
        success: (CanonicalTranscript) -> String
    ) {
        guard let transcript = files.first(where: { $0.id == fileID })?.transcript else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "This file has no transcript to edit.", isFailure: true)
            return
        }
        do {
            let revised = try edit(transcript)
            guard revised != transcript else { return }
            undoStacks[fileID, default: []].append(transcript)
            redoStacks[fileID] = []
            replaceTranscript(revised, inFileID: fileID)
            nextToastAction = .undo
            speakerActionMessage = TranscriptSpeakerActionMessage(text: success(revised), isFailure: false)
        } catch {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: Self.describe(error), isFailure: true)
        }
    }

    /// Records a new revision in memory and, when the host attached a store, on
    /// disk. A revision that cannot be persisted is still shown, and the failure
    /// is reported rather than swallowed: the words are unchanged either way.
    private func replaceSelectedTranscript(_ transcript: CanonicalTranscript) {
        guard let selectedFileID else { return }
        replaceTranscript(transcript, inFileID: selectedFileID)
    }

    private func replaceTranscript(_ transcript: CanonicalTranscript, inFileID fileID: TranscriptReviewFile.ID) {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        let file = files[index].replacingTranscript(transcript)
        files[index] = file
        do {
            guard let runID = file.runID else { return }
            try revisionStore?.save(transcript, forFileID: runID)
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
        toastCenter.clearReversibleActions()
        cancelRememberingVoice()
        stopPlayback()
        speakerFilterID = nil
        playheadMilliseconds = 0
        guard let file = selectedFile else {
            selectedSegmentID = nil
            exportMessage = nil
            return
        }
        if !file.isPlaceholder { playback.load(sourceSnapshotURL: file.sourceSnapshotURL) }
        selectedSegmentID = nil
        exportMessage = nil
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}

/// One version of a transcript's turns, in time order, with its reading
/// paragraphs and the lookups list rows need. Paragraphs are grouped on first
/// use: the segment layout never asks for them.
private final class TranscriptOrder {
    let source: [TranscriptSegment]
    let segments: [TranscriptSegment]
    let segmentIndexByID: [TranscriptSegment.ID: Int]
    private var grouped: (paragraphs: [TranscriptParagraph], indexBySegmentID: [TranscriptSegment.ID: Int])?

    init(source: [TranscriptSegment]) {
        self.source = source
        segments = source.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        segmentIndexByID = Dictionary(segments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var paragraphs: [TranscriptParagraph] { group().paragraphs }

    /// The paragraph holding each turn, asides included; the first wins, as
    /// a search from the top did.
    var paragraphIndexBySegmentID: [TranscriptSegment.ID: Int] { group().indexBySegmentID }

    private func group() -> (paragraphs: [TranscriptParagraph], indexBySegmentID: [TranscriptSegment.ID: Int]) {
        if let grouped { return grouped }
        let paragraphs = TranscriptParagraphGrouper().paragraphs(from: segments)
        var index: [TranscriptSegment.ID: Int] = [:]
        for (offset, paragraph) in paragraphs.enumerated() {
            for id in paragraph.allSourceSegmentIDs where index[id] == nil { index[id] = offset }
        }
        let result = (paragraphs, index)
        grouped = result
        return result
    }
}
