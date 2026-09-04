import Foundation
import Speakers
import XCTest
@testable import Transcription

@MainActor
final class TranscriptSpeakerAssignmentTests: XCTestCase {
    private let sarah = SpeakerPersonRef(profileID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "Sarah")
    private let alex = SpeakerPersonRef(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "Alex")

    // MARK: - Manual assignment

    func testAssigningAClusterRelabelsExportsWithoutRerunningRecognition() throws {
        let original = try fixture(named: "two-speakers")
        let viewModel = try makeViewModel(transcript: original)

        viewModel.assign(sarah, scope: .cluster(speakerID: "speaker_2"))

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.revision, original.revision + 1)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Sarah")
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.profileID, sarah.profileID.uuidString)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.identityAssignment, .manual)
        XCTAssertEqual(revised.segments.first { $0.speakerID == "speaker_2" }?.speakerLabel, "Sarah")

        // Recognition output is untouched: only labels changed, so no ASR rerun is implied.
        XCTAssertEqual(revised.segments.map(\.text), original.segments.map(\.text))
        XCTAssertEqual(revised.segments.map(\.startMs), original.segments.map(\.startMs))
        XCTAssertEqual(revised.segments.map(\.endMs), original.segments.map(\.endMs))
        XCTAssertEqual(revised.segments.map(\.words), original.segments.map(\.words))
        XCTAssertEqual(revised.engineRevisions, original.engineRevisions)
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))

        let text = String(decoding: try TranscriptExporter.export(revised, as: .plainText), as: UTF8.self)
        XCTAssertTrue(text.contains("Sarah: Yes, I have the notes."), text)
        XCTAssertFalse(text.contains("Speaker 2:"), text)
    }

    func testAssigningASingleTurnMovesOnlyThatSegment() throws {
        let original = try fixture(named: "two-speakers")
        let viewModel = try makeViewModel(transcript: original)

        viewModel.assign(sarah, scope: .turn(segmentID: "segment_001"))

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        let moved = try XCTUnwrap(revised.segments.first { $0.id == "segment_001" })
        XCTAssertEqual(moved.speakerLabel, "Sarah")
        XCTAssertNotEqual(moved.speakerID, "speaker_1")
        XCTAssertEqual(revised.segments.first { $0.id == "segment_002" }?.speakerLabel, "Speaker 2")
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_1" }?.labelSnapshot, "Alex", "the original cluster keeps its own label")
        XCTAssertNoThrow(try CanonicalTranscriptValidator.validate(revised))

        let text = String(decoding: try TranscriptExporter.export(revised, as: .plainText), as: UTF8.self)
        XCTAssertTrue(text.contains("Sarah: Can we begin?"), text)
    }

    func testASecondTurnAssignmentReusesTheSamePersonEntry() throws {
        let viewModel = try makeViewModel(transcript: try fixture(named: "two-speakers"))

        viewModel.assign(sarah, scope: .turn(segmentID: "segment_001"))
        viewModel.assign(sarah, scope: .turn(segmentID: "segment_002"))

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        let sarahEntries = revised.speakers.filter { $0.profileID == sarah.profileID.uuidString }
        XCTAssertEqual(sarahEntries.count, 1)
        XCTAssertEqual(Set(revised.segments.compactMap(\.speakerID)), [try XCTUnwrap(sarahEntries.first).id])
    }

    func testClearingAnAssignmentRestoresTheGenericLabel() throws {
        let viewModel = try makeViewModel(transcript: try fixture(named: "two-speakers"))

        viewModel.assign(nil, scope: .cluster(speakerID: "speaker_1"))

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_1" }?.labelSnapshot, "Speaker 1")
        XCTAssertNil(revised.speakers.first { $0.id == "speaker_1" }?.profileID)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_1" }?.identityAssignment, .unmatched)
        XCTAssertEqual(revised.segments.first { $0.id == "segment_001" }?.speakerLabel, "Speaker 1")
    }

    func testAssigningANewPersonCreatesANameOnlyProfileInTheLibrary() async throws {
        let directory = DirectorySpy()
        let viewModel = try makeViewModel(transcript: try fixture(named: "two-speakers"), directory: directory)

        await viewModel.assignNewPerson(named: "Dana", scope: .cluster(speakerID: "speaker_2"))

        XCTAssertEqual(directory.createdNames, ["Dana"])
        XCTAssertTrue(directory.enrollments.isEmpty, "naming someone must not enroll a voice")
        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Dana")
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.identityAssignment, .manual)
    }

    // MARK: - Suggested matches

    func testConfirmingASuggestionAppliesItAsAManualAssignment() throws {
        let suggestion = TranscriptSpeakerSuggestion(speakerID: "speaker_2", person: sarah, score: 0.74, matcherVersion: "speaker-identity-matcher/1")
        let viewModel = try makeViewModel(transcript: try fixture(named: "two-speakers"), suggestions: [suggestion])

        XCTAssertEqual(viewModel.speakerRows.first { $0.speakerID == "speaker_2" }?.label, "Speaker 2", "a suggestion keeps the generic label")

        viewModel.confirm(suggestion)

        let revised = try XCTUnwrap(viewModel.selectedTranscript)
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Sarah")
        XCTAssertEqual(revised.speakers.first { $0.id == "speaker_2" }?.identityAssignment, .manual)
        XCTAssertTrue(viewModel.pendingSuggestions.isEmpty)
    }

    func testDismissingASuggestionKeepsTheGenericLabelAndTheSavedRevision() throws {
        let suggestion = TranscriptSpeakerSuggestion(speakerID: "speaker_2", person: sarah, score: 0.71, matcherVersion: "speaker-identity-matcher/1")
        let original = try fixture(named: "two-speakers")
        let viewModel = try makeViewModel(transcript: original, suggestions: [suggestion])

        viewModel.dismiss(suggestion)

        XCTAssertTrue(viewModel.pendingSuggestions.isEmpty)
        XCTAssertEqual(viewModel.selectedTranscript?.revision, original.revision)
        XCTAssertEqual(viewModel.selectedTranscript?.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Speaker 2")
    }

    func testOnlySuggestedMatcherOutcomesBecomeReviewSuggestions() {
        let evidence = SpeakerIdentityScoreEvidence(
            candidates: [SpeakerIdentityCandidateScore(profile: sarah, score: 0.72, supportingExcerptCount: 1)],
            cleanExcerptCount: 2,
            libraryRevision: SpeakerLibraryRevision(sequence: 4),
            matcherVersion: "speaker-identity-matcher/1",
            automaticThreshold: 0.85,
            suggestionThreshold: 0.7,
            minimumMargin: 0.05,
            minimumConsistentExcerpts: 2
        )
        let suggested = Speakers.SpeakerIdentityAssignment(
            recordingSpeakerID: "speaker_2",
            outcome: .suggested,
            assignmentMethod: .suggestedForReview,
            person: sarah,
            evidence: evidence
        )
        let unmatched = Speakers.SpeakerIdentityAssignment(
            recordingSpeakerID: "speaker_3",
            outcome: .unmatched,
            assignmentMethod: .unmatched,
            person: nil,
            evidence: evidence
        )

        XCTAssertEqual(TranscriptSpeakerSuggestion(suggested)?.person, sarah)
        XCTAssertEqual(TranscriptSpeakerSuggestion(suggested)?.score, 0.72)
        XCTAssertNil(TranscriptSpeakerSuggestion(unmatched))
    }

    // MARK: - Label refresh

    func testRefreshingLabelsCreatesANewRevisionBeforeExport() async throws {
        let directory = DirectorySpy(people: [sarah])
        let assigned = try TranscriptSpeakerLabelEditor.assigning(
            person: sarah,
            scope: .cluster(speakerID: "speaker_2"),
            in: try fixture(named: "two-speakers")
        )
        let viewModel = try makeViewModel(transcript: assigned, directory: directory)

        directory.people = [SpeakerPersonRef(profileID: sarah.profileID, displayName: "Sarah Chen")]
        let writer = RecordingExportWriter()
        let recording = try makeViewModel(transcript: assigned, directory: directory, exportWriter: writer)
        await recording.exportRefreshingLabels([.plainText], to: URL(fileURLWithPath: "/tmp"))

        let exported = try XCTUnwrap(writer.exported)
        XCTAssertEqual(exported.revision, assigned.revision + 1)
        XCTAssertEqual(exported.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Sarah Chen")
        XCTAssertEqual(exported.segments.first { $0.speakerID == "speaker_2" }?.speakerLabel, "Sarah Chen")

        await viewModel.refreshLabelsFromLibrary()
        XCTAssertEqual(viewModel.selectedTranscript?.revision, assigned.revision + 1)
    }

    func testRefreshingLabelsIsANoOpWhenNamesAlreadyMatch() async throws {
        let assigned = try TranscriptSpeakerLabelEditor.assigning(
            person: sarah,
            scope: .cluster(speakerID: "speaker_2"),
            in: try fixture(named: "two-speakers")
        )
        let viewModel = try makeViewModel(transcript: assigned, directory: DirectorySpy(people: [sarah]))

        await viewModel.refreshLabelsFromLibrary()

        XCTAssertEqual(viewModel.selectedTranscript?.revision, assigned.revision)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, false)
    }

    func testADeletedProfileKeepsTheLabelTheRevisionAlreadySaved() throws {
        let assigned = try TranscriptSpeakerLabelEditor.assigning(
            person: sarah,
            scope: .cluster(speakerID: "speaker_2"),
            in: try fixture(named: "two-speakers")
        )

        let refreshed = TranscriptSpeakerLabelEditor.refreshingLabels(using: [alex], in: assigned)

        XCTAssertNil(refreshed, "a deleted person does not revert a saved transcript label")
        XCTAssertEqual(assigned.speakers.first { $0.id == "speaker_2" }?.labelSnapshot, "Sarah")
    }

    // MARK: - Remember this voice

    func testEnrollmentCandidatesExcludeOverlapEstimatedTimingAndShortTurns() throws {
        let overlapping = try fixture(named: "dense-overlap")
        let candidates = TranscriptEnrollmentCandidates.candidates(forSpeakerID: "speaker_1", in: overlapping)

        XCTAssertEqual(candidates.map(\.segmentID), ["segment_001", "segment_004", "segment_005"])
        XCTAssertEqual(candidates.first { $0.segmentID == "segment_001" }?.exclusionReason, "Overlapping speech")
        XCTAssertEqual(candidates.first { $0.segmentID == "segment_004" }?.exclusionReason, "Overlapping speech")
        XCTAssertNil(candidates.first { $0.segmentID == "segment_005" }?.exclusionReason)
        XCTAssertTrue(candidates.allSatisfy { !$0.isConfirmed }, "nothing is enrolled without explicit confirmation")
        XCTAssertTrue(TranscriptEnrollmentCandidates.excerpts(from: candidates).isEmpty)

        let estimated = try fixture(named: "long-turns")
        let estimatedCandidates = TranscriptEnrollmentCandidates.candidates(forSpeakerID: "speaker_1", in: estimated)
        XCTAssertEqual(estimatedCandidates.compactMap(\.exclusionReason), ["Estimated timing", "Estimated timing"])

        let brief = TranscriptEnrollmentCandidates.candidates(forSpeakerID: "speaker_1", in: try fixture(named: "four-speakers"))
        XCTAssertEqual(brief.compactMap(\.exclusionReason), ["Estimated timing"])
        XCTAssertEqual(
            TranscriptEnrollmentCandidates.candidates(forSpeakerID: "speaker_1", in: try fixture(named: "one-speaker"), minimumUtteranceDuration: 5)
                .compactMap(\.exclusionReason),
            ["Shorter than 5s"]
        )
    }

    func testRememberingAVoiceEnrollsOnlyConfirmedCleanExcerpts() async throws {
        let directory = DirectorySpy()
        let transcript = try fixture(named: "dense-overlap")
        let viewModel = try makeViewModel(transcript: transcript, directory: directory)

        viewModel.beginRememberingVoice(speakerID: "speaker_1")
        let eligible = viewModel.enrollmentCandidates.filter(\.isEligible)
        XCTAssertFalse(eligible.isEmpty)
        for candidate in eligible { viewModel.setCandidate(candidate.segmentID, confirmed: true) }
        for candidate in viewModel.enrollmentCandidates where !candidate.isEligible {
            viewModel.setCandidate(candidate.segmentID, confirmed: true)
            XCTAssertFalse(
                viewModel.enrollmentCandidates.first { $0.segmentID == candidate.segmentID }?.isConfirmed ?? true,
                "an excluded excerpt cannot be confirmed"
            )
        }

        await viewModel.rememberVoice(target: .newProfile(displayName: "Sarah"), retainClips: true)

        let request = try XCTUnwrap(directory.enrollments.first)
        XCTAssertEqual(request.confirmation, .userConfirmedExcerpts)
        XCTAssertEqual(request.origin, .transcriptSelection)
        XCTAssertEqual(request.target, .newProfile(displayName: "Sarah"))
        XCTAssertEqual(request.sourceID, transcript.transcriptID)
        XCTAssertEqual(request.excerpts.count, eligible.count)
        XCTAssertTrue(request.excerpts.allSatisfy { $0.isConfirmed && !$0.containsOverlap })
        XCTAssertTrue(request.retainClips)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, false)
        XCTAssertNil(viewModel.enrollmentSpeakerID, "the sheet closes once the voice is remembered")
    }

    func testRememberingAVoiceWithNoConfirmedExcerptsDoesNotReachTheLibrary() async throws {
        let directory = DirectorySpy()
        let transcript = try fixture(named: "dense-overlap")
        let viewModel = try makeViewModel(transcript: transcript, directory: directory)

        viewModel.beginRememberingVoice(speakerID: "speaker_1")
        await viewModel.rememberVoice(target: .newProfile(displayName: "Sarah"))

        XCTAssertTrue(directory.enrollments.isEmpty)
        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
    }

    func testEnrollmentFailuresAreReportedWithoutChangingLabels() async throws {
        let directory = DirectorySpy()
        directory.enrollmentError = SpeakerEnrollmentError.insufficientUsableSpeech(seconds: 6, required: 20)
        let transcript = try fixture(named: "dense-overlap")
        let viewModel = try makeViewModel(transcript: transcript, directory: directory)

        viewModel.beginRememberingVoice(speakerID: "speaker_1")
        for candidate in viewModel.enrollmentCandidates.filter(\.isEligible) {
            viewModel.setCandidate(candidate.segmentID, confirmed: true)
        }
        await viewModel.rememberVoice(target: .newProfile(displayName: "Sarah"))

        XCTAssertEqual(viewModel.speakerActionMessage?.isFailure, true)
        XCTAssertTrue(viewModel.speakerActionMessage?.text.contains("Usable speech is") ?? false)
        XCTAssertEqual(viewModel.selectedTranscript?.revision, transcript.revision)
        XCTAssertNotNil(viewModel.enrollmentSpeakerID, "the sheet stays open so the user can confirm more excerpts")
    }

    // MARK: - Helpers

    private func makeViewModel(
        transcript: CanonicalTranscript,
        suggestions: [TranscriptSpeakerSuggestion] = [],
        directory: (any TranscriptSpeakerDirectory)? = nil,
        exportWriter: any TranscriptExportWriting = FileTranscriptExportWriter()
    ) throws -> TranscriptViewModel {
        TranscriptViewModel(
            files: [
                TranscriptReviewFile(
                    sourceSnapshotURL: URL(fileURLWithPath: "/tmp/scribe-review-snapshot.flac"),
                    transcript: transcript,
                    jobState: .complete,
                    suggestions: suggestions
                )
            ],
            playback: PlaybackStub(),
            exportWriter: exportWriter,
            directory: directory
        )
    }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

@MainActor
private final class PlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL _: URL) {}
    func seek(toMilliseconds _: Int) {}
}

private final class DirectorySpy: TranscriptSpeakerDirectory, @unchecked Sendable {
    var people: [SpeakerPersonRef]
    var enrollmentError: (any Error)?
    private(set) var createdNames: [String] = []
    private(set) var enrollments: [SpeakerEnrollmentRequest] = []

    init(people: [SpeakerPersonRef] = []) {
        self.people = people
    }

    func people() async throws -> [SpeakerPersonRef] { people }

    func createPerson(named name: String) async throws -> SpeakerPersonRef {
        createdNames.append(name)
        let person = SpeakerPersonRef(profileID: UUID(), displayName: name)
        people.append(person)
        return person
    }

    func enroll(_ request: SpeakerEnrollmentRequest) async throws -> SpeakerEnrollmentResult {
        if let enrollmentError { throw enrollmentError }
        enrollments.append(request)
        let name: String = switch request.target {
        case let .newProfile(displayName): displayName
        case let .existingProfile(id): people.first { $0.profileID == id }?.displayName ?? "Unknown"
        }
        let profile = SpeakerProfile(
            profileID: UUID(),
            displayName: name,
            automaticMatchingEnabled: true,
            signatures: [],
            createdAt: Date(),
            updatedAt: Date()
        )
        return SpeakerEnrollmentResult(
            origin: request.origin,
            profile: profile,
            selectedExcerpts: request.excerpts,
            usableSpeechDuration: request.excerpts.reduce(0) { $0 + $1.duration },
            libraryRevision: SpeakerLibraryRevision(sequence: 2)
        )
    }
}

private final class RecordingExportWriter: TranscriptExportWriting, @unchecked Sendable {
    private(set) var exported: CanonicalTranscript?

    func write(
        _ transcript: CanonicalTranscript,
        formats: Set<TranscriptExportFormat>,
        to directoryURL: URL
    ) -> [TranscriptExportOutcome] {
        exported = transcript
        return formats.map {
            TranscriptExportOutcome(format: $0, destinationURL: directoryURL.appendingPathComponent("out.\($0.fileExtension)"), errorMessage: nil)
        }
    }
}
