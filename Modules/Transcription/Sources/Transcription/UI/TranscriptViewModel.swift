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

    private func handle(_ event: TranscriptPlaybackEvent) {
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
        guard let transcript = selectedTranscript else {
            speakerActionMessage = TranscriptSpeakerActionMessage(text: "This file has no transcript to relabel.", isFailure: true)
            return
        }
        do {
            let revised = try edit(transcript)
            replaceSelectedTranscript(revised)
            speakerActionMessage = TranscriptSpeakerActionMessage(text: success(), isFailure: false)
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
