import Foundation
import Observation
import Speakers

/// One recording-local speaker as the review window presents it.
public struct TranscriptSpeakerRow: Identifiable, Equatable, Sendable {
    public let speakerID: String
    public let label: String
    public let assignment: SpeakerIdentityAssignment
    public let profileID: String?
    public let segmentCount: Int
    public let suggestion: TranscriptSpeakerSuggestion?

    public var id: String { speakerID }

    public var statusDescription: String {
        if let suggestion {
            return "Suggested: \(suggestion.person.displayName) (\(suggestion.scoreDescription)) — confirm to apply"
        }
        return switch assignment {
        case .manual: "Assigned by you"
        case .automatic: "Matched from your speaker library"
        case .unmatched: "Not matched to a saved person"
        }
    }

    public init(
        speakerID: String,
        label: String,
        assignment: SpeakerIdentityAssignment,
        profileID: String?,
        segmentCount: Int,
        suggestion: TranscriptSpeakerSuggestion?
    ) {
        self.speakerID = speakerID
        self.label = label
        self.assignment = assignment
        self.profileID = profileID
        self.segmentCount = segmentCount
        self.suggestion = suggestion
    }
}

/// Result of an assignment, enrollment, or label-refresh action.
public struct TranscriptSpeakerActionMessage: Equatable, Sendable {
    public let text: String
    public let isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }
}

/// What the transport bar shows while the selected source is playing.
public struct TranscriptPlaybackStatus: Equatable, Sendable {
    /// The turn whose words are being spoken, or the last one that started
    /// when the play head is in a pause between turns.
    public let segment: TranscriptSegment
    public let isPlaying: Bool

    public init(segment: TranscriptSegment, isPlaying: Bool) {
        self.segment = segment
        self.isPlaying = isPlaying
    }

    public var speakerLabel: String { segment.speakerLabel }

    /// The turn's own bounds, which is what a listener is placing the words against.
    public var timestamp: String {
        "\(TranscriptTimecode.string(fromMilliseconds: segment.startMs)) – \(TranscriptTimecode.string(fromMilliseconds: segment.endMs))"
    }
}

/// Which turns the transcript list shows.
public enum TranscriptReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case needsReview
    case unknownSpeaker
    case overlap
    case estimatedTiming

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "All turns"
        case .needsReview: "Needs review"
        case .unknownSpeaker: "Unknown speaker"
        case .overlap: "Overlapping speech"
        case .estimatedTiming: "Estimated timing"
        }
    }

    public func matches(_ segment: TranscriptSegment) -> Bool {
        switch self {
        case .all: true
        case .needsReview: segment.needsReview
        case .unknownSpeaker: segment.speakerID == nil
        case .overlap: segment.overlap
        case .estimatedTiming: segment.timingQuality == .segmentOnly
        }
    }
}

public extension TranscriptSegment {
    /// Below this the diarizer was guessing, which is worth a second listen.
    static let lowSpeakerConfidence = 0.5

    var hasLowSpeakerConfidence: Bool {
        guard let speakerConfidence else { return false }
        return speakerConfidence < Self.lowSpeakerConfidence
    }

    /// A turn a reviewer should look at: no speaker, an uncertain one,
    /// overlapping speech, or timing that was estimated rather than measured.
    var needsReview: Bool {
        speakerID == nil || hasLowSpeakerConfidence || overlap || timingQuality == .segmentOnly
    }
}

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

    public init(
        files: [TranscriptReviewFile],
        selectedFileID: TranscriptReviewFile.ID? = nil,
        playback: any TranscriptPlaybackSeeking,
        exportWriter: any TranscriptExportWriting = FileTranscriptExportWriter(),
        directory: (any TranscriptSpeakerDirectory)? = nil,
        revisionStore: (any TranscriptRevisionStoring)? = nil,
        fileDeleter: (any TranscriptFileDeleting)? = nil
    ) {
        self.files = files
        self.selectedFileID = selectedFileID ?? files.first?.id
        self.playback = playback
        self.exportWriter = exportWriter
        self.directory = directory
        self.revisionStore = revisionStore
        self.fileDeleter = fileDeleter
        selectFileIfNeeded()
        playback.setPlaybackObserver { [weak self] event in self?.handle(event) }
    }

    /// Replaces the list as the job pipeline reports new state.
    ///
    /// The selection is a person's place in the window, not derived state, so it
    /// survives a refresh whenever the file it names is still present. A file
    /// whose transcript has been relabelled in this window keeps the revision on
    /// screen when the incoming copy is not newer, so a routine refresh cannot
    /// silently discard an edit that is still being made.
    public func reload(files incoming: [TranscriptReviewFile]) {
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

    /// The speakers this recording has, in table order.
    public var recordingSpeakers: [TranscriptSpeaker] { selectedTranscript?.speakers ?? [] }

    public var sourceDurationMilliseconds: Int { selectedTranscript?.source.durationMs ?? 0 }

    /// The turns the list shows after search and filters.
    public var visibleSegments: [TranscriptSegment] {
        let query = Self.normalizedSearch(searchText)
        return chronologicalSegments.filter { segment in
            if let speakerFilterID, segment.speakerID != speakerFilterID { return false }
            guard reviewFilter.matches(segment) else { return false }
            guard !query.isEmpty else { return true }
            return Self.normalizedSearch(segment.text).contains(query)
                || Self.normalizedSearch(segment.speakerLabel).contains(query)
        }
    }

    public var isFiltering: Bool {
        !Self.normalizedSearch(searchText).isEmpty || speakerFilterID != nil || reviewFilter != .all
    }

    public var segmentsNeedingReviewCount: Int {
        chronologicalSegments.filter(\.needsReview).count
    }

    /// A one-line account of the recording: turns, speakers, and length.
    public var reviewSummary: String? {
        guard let transcript = selectedTranscript else { return nil }
        let turns = transcript.segments.count
        let speakers = transcript.speakers.count
        var parts = [
            "\(turns) turn\(turns == 1 ? "" : "s")",
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

    public func select(segment: TranscriptSegment) {
        selectedSegmentID = segment.id
        playheadMilliseconds = segment.startMs
        playback.seek(toMilliseconds: segment.startMs)
        // A seek while playing moves the readout with the audio; a seek while
        // paused or stopped is only a selection and must not start sound.
        if isPlaying { playingSegmentID = segment.id }
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
        let segments = chronologicalSegments
        let candidates = segments.filter(\.needsReview)
        guard !candidates.isEmpty else { return false }
        let start = segments.firstIndex { $0.id == selectedSegmentID } ?? -1
        let next = segments.enumerated().first { $0.offset > start && $0.element.needsReview }?.element
            ?? candidates[0]
        select(segment: next)
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

    /// Exports each requested format separately so an SRT failure does not lose valid TXT/JSON.
    public func export(_ formats: Set<TranscriptExportFormat>, to directoryURL: URL) {
        guard let transcript = selectedTranscript else {
            exportOutcomes = formats.map {
                TranscriptExportOutcome(format: $0, destinationURL: nil, errorMessage: "This file has no completed transcript to export.")
            }
            return
        }
        exportOutcomes = exportWriter.write(transcript, formats: formats, to: directoryURL)
    }

    /// Brings saved labels up to date with the library, then exports that revision.
    public func exportRefreshingLabels(_ formats: Set<TranscriptExportFormat>, to directoryURL: URL) async {
        await refreshLabelsFromLibrary(announceUnchanged: false)
        export(formats, to: directoryURL)
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
