import Foundation
import XCTest
@testable import Transcription

/// Regressions for the long-file token-duration defect investigated in
/// `docs/investigations/diarization-979.md`.
///
/// FluidAudio v0.12.4 never populated `TdtHypothesis.tokenDurations`, so
/// `createTokenTimings` ended every token where the *next* one started. A word
/// before a pause therefore swallowed the pause: in the investigated meeting no
/// two adjacent words were ever 1 s apart, 440 words ran over a second, one
/// `you.` covered 16.64 s, and 833 words fell to the unknown speaker because
/// `SpeakerTurnBuilder` needs half of the word interval to overlap one speaker.
///
/// Each test below feeds worker tokens whose ends are real acoustic durations
/// and pins the host behaviour that only holds when those durations survive. The
/// `pre-0.12.5` variants reproduce the old endpoint substitution to show the
/// assertions actually discriminate. Times are source-relative seconds
/// throughout; nothing here shifts the recording's own timeline.
final class TokenDurationPauseRegressionTests: XCTestCase {
    private let reconciler = TokenTimingReconciler()
    private let builder = SpeakerTurnBuilder()
    private let identityMapping = AudioTimeMapping(sourceSampleRate: 16_000)

    // MARK: - Long mid-recording pause

    func testLongMidRecordingPauseSurvivesAsAGapRatherThanAStretchedWord() throws {
        // "Right." at 600 s, then 30 s of silence, then the same speaker resumes.
        let tokens = [
            token(" Right", id: 10, start: 600.00, end: 600.40),
            token(".", id: 7883, start: 600.40, end: 600.48),
            token(" Anyway", id: 11, start: 630.00, end: 630.56),
            token(",", id: 7952, start: 630.56, end: 630.64),
        ]
        let result = try reconcile(tokens, durationMs: 700_000)

        XCTAssertEqual(result.texts, ["Right.", "Anyway,"])
        // The word before the pause keeps its own extent instead of reaching the
        // next onset, which is the whole defect.
        XCTAssertEqual(result.words[0].endMs, 600_400)
        XCTAssertEqual(maximumWordDurationMs(result), 560)
        XCTAssertEqual(longestAdjacentGapMs(result), 29_600)

        // A real gap is what lets the one-second pause split do any work.
        let built = try builder.build(
            words: result.words,
            diarizedTurns: [DiarizedSpeakerTurn(speakerID: "A", startMs: 599_900, endMs: 631_000)]
        )
        XCTAssertEqual(built.segments.count, 2)
        XCTAssertEqual(built.segments.map(\.text), ["Right.", "Anyway,"])
    }

    func testPreFixEndpointSubstitutionWouldHaveHiddenThatPause() throws {
        // A speaker trails off mid-sentence, so no punctuation is decoded before
        // the silence. Under v0.12.4 endpoint substitution "and" ran to the next
        // onset and the 30 s pause vanished.
        let acoustic = [
            token(" and", id: 12, start: 600.00, end: 600.32),
            token(" anyway", id: 11, start: 630.00, end: 630.56),
        ]
        let substituted = try reconcile(endingEachTokenAtTheNextTokensStart(acoustic), durationMs: 700_000)
        XCTAssertEqual(substituted.words[0].endMs, 630_000)
        XCTAssertEqual(longestAdjacentGapMs(substituted), 0)

        // Real durations expose the same pause.
        let repaired = try reconcile(acoustic, durationMs: 700_000)
        XCTAssertEqual(repaired.words[0].endMs, 600_320)
        XCTAssertEqual(longestAdjacentGapMs(repaired), 29_680)
    }

    func testPunctuationFixAloneAlreadyBlocksSubstitutionOnSentenceFinalWords() throws {
        // The two defects overlap on sentence-final words: v0.12.4 pushed the
        // pause into the terminal mark, and the host then absorbed the mark's
        // timing. Ignoring punctuation timing removes that path on its own,
        // which is why the old transcript already improved when replayed.
        let result = try reconcile(
            endingEachTokenAtTheNextTokensStart([
                token(" Right", id: 10, start: 600.00, end: 600.40),
                token(".", id: 7883, start: 600.40, end: 600.48),
                token(" Anyway", id: 11, start: 630.00, end: 630.56),
            ]),
            durationMs: 700_000
        )

        XCTAssertEqual(result.texts, ["Right.", "Anyway"])
        XCTAssertEqual(result.words[0].endMs, 600_400)
        XCTAssertEqual(longestAdjacentGapMs(result), 29_600)
    }

    // MARK: - Short acknowledgment

    func testShortAcknowledgmentKeepsItsOwnSpeaker() throws {
        // B says "Mm-hm." for 340 ms inside a long A turn, then A resumes 5 s later.
        let words = [
            word("word_001", "So", start: 100_000, end: 100_320),
            word("word_002", "Mm-hm.", start: 101_000, end: 101_340),
            word("word_003", "anyway", start: 106_000, end: 106_480),
        ]
        let turns = [
            DiarizedSpeakerTurn(speakerID: "A", startMs: 99_800, endMs: 100_600),
            DiarizedSpeakerTurn(speakerID: "B", startMs: 100_900, endMs: 101_450),
            DiarizedSpeakerTurn(speakerID: "A", startMs: 105_800, endMs: 106_900),
        ]
        let built = try builder.build(words: words, diarizedTurns: turns)

        XCTAssertEqual(speakerIDs(built), ["speaker_1", "speaker_2", "speaker_1"])
        XCTAssertEqual(built.segments.map(\.text), ["So", "Mm-hm.", "anyway"])
    }

    func testPreFixAcknowledgmentWouldHaveFallenToUnknown() throws {
        // The same acknowledgment when its end was the next word's start: a
        // 5.34 s interval needs 2.67 s inside one speaker, and B only has 450 ms.
        let words = [
            word("word_001", "So", start: 100_000, end: 101_000),
            word("word_002", "Mm-hm.", start: 101_000, end: 106_000),
            word("word_003", "anyway", start: 106_000, end: 106_480),
        ]
        let turns = [
            DiarizedSpeakerTurn(speakerID: "A", startMs: 99_800, endMs: 100_600),
            DiarizedSpeakerTurn(speakerID: "B", startMs: 100_900, endMs: 101_450),
            DiarizedSpeakerTurn(speakerID: "A", startMs: 105_800, endMs: 106_900),
        ]
        let built = try builder.build(words: words, diarizedTurns: turns)

        XCTAssertEqual(speakerIDs(built)[1], nil)
    }

    // MARK: - Chunk-boundary word

    func testChunkBoundaryWordKeepsItsAcousticEndAfterDeduplication() throws {
        // "wait." is decoded at the seam by both windows and is followed by a
        // 9 s pause. The surviving copy must keep its 400 ms extent.
        let transcript = WorkerASRTranscript(
            text: "Please wait. The weather",
            tokens: [],
            chunks: [
                WorkerASRChunk(chunkIndex: 0, chunkStartSeconds: 0, tokens: [
                    token(" Please", id: 10, start: 11.60, end: 12.00),
                    token(" wait", id: 11, start: 12.40, end: 12.80),
                    token(".", id: 7883, start: 12.80, end: 12.88),
                ]),
                WorkerASRChunk(chunkIndex: 1, chunkStartSeconds: 12.88, tokens: [
                    token(" wait", id: 11, start: 12.40, end: 12.80),
                    token(".", id: 7883, start: 12.80, end: 12.88),
                    token(" The", id: 20, start: 21.80, end: 22.00),
                    token(" weather", id: 21, start: 22.00, end: 22.48),
                ]),
            ],
            sourceDurationSeconds: 40.603,
            usedChunkedProcessing: true
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: identityMapping,
            sourceDurationMs: 40_603
        ))

        XCTAssertEqual(result.texts, ["Please", "wait.", "The", "weather"])
        XCTAssertEqual(result.droppedDuplicateTokenCount, 2)
        XCTAssertEqual(result.words[1].startMs, 12_400)
        XCTAssertEqual(result.words[1].endMs, 12_800)
        XCTAssertEqual(longestAdjacentGapMs(result), 9_000)
    }

    // MARK: - Overlapping speech

    func testOverlappingSpeakersAreFlaggedAndLeftUnknownOnTiedEvidence() throws {
        let words = [word("word_001", "together", start: 40_000, end: 40_600)]
        let turns = [
            DiarizedSpeakerTurn(speakerID: "A", startMs: 39_800, endMs: 40_600),
            DiarizedSpeakerTurn(speakerID: "B", startMs: 40_000, endMs: 40_800),
        ]
        let built = try builder.build(words: words, diarizedTurns: turns)

        // Both cover the whole acoustic word, so neither wins and the ambiguity
        // is preserved rather than resolved by an arbitrary tie-break.
        XCTAssertEqual(speakerIDs(built), [nil])
        XCTAssertTrue(built.segments[0].overlap)
        XCTAssertEqual(built.speakers.count, 2)
    }

    func testOverlapDoesNotSuppressAClearWinner() throws {
        let words = [word("word_001", "mine", start: 40_000, end: 40_600)]
        let turns = [
            DiarizedSpeakerTurn(speakerID: "A", startMs: 39_800, endMs: 40_600),
            DiarizedSpeakerTurn(speakerID: "B", startMs: 40_500, endMs: 40_800),
        ]
        let built = try builder.build(words: words, diarizedTurns: turns)

        XCTAssertEqual(speakerIDs(built), ["speaker_1"])
        XCTAssertTrue(built.segments[0].overlap)
    }

    // MARK: - Legitimate long word

    func testGenuinelyLongWordIsPreservedRatherThanClipped() throws {
        // A drawn-out 1.44 s "Soooo," is real speech, not a swallowed pause. The
        // investigation's diagnostic 320 ms attribution window was explicitly
        // not shipped, and this pins that: nothing may truncate acoustic extent.
        let tokens = [
            token(" So", id: 30, start: 200.00, end: 200.64),
            token("ooo", id: 31, start: 200.64, end: 201.44),
            token(",", id: 7952, start: 201.44, end: 201.52),
        ]
        let result = try reconcile(tokens, durationMs: 300_000)

        XCTAssertEqual(result.texts, ["Soooo,"])
        XCTAssertEqual(result.words[0].startMs, 200_000)
        XCTAssertEqual(result.words[0].endMs, 201_440)

        let built = try builder.build(
            words: result.words,
            diarizedTurns: [DiarizedSpeakerTurn(speakerID: "A", startMs: 199_900, endMs: 201_500)]
        )
        XCTAssertEqual(speakerIDs(built), ["speaker_1"])
        XCTAssertEqual(built.segments[0].words?.first?.endMs, 201_440)
    }

    // MARK: - Punctuation

    func testTerminalPunctuationAddsTextWithoutReachingIntoTheFollowingPause() throws {
        // The decoder settles the period 2 s after the speech it closes. The
        // mark belongs to the word's text and to nothing else.
        let tokens = [
            token(" Done", id: 40, start: 50.00, end: 50.48),
            token(".", id: 7883, start: 52.00, end: 52.08),
        ]
        let result = try reconcile(tokens, durationMs: 60_000)

        XCTAssertEqual(result.texts, ["Done."])
        XCTAssertEqual(result.words[0].endMs, 50_480)
    }

    func testTrailingPunctuationWithNoLexicalTokenStillKeepsItsText() throws {
        let tokens = [
            token(" Done", id: 40, start: 50.00, end: 50.48),
            token("?", id: 7952, start: 50.48, end: 50.56),
            token("!", id: 7948, start: 50.56, end: 50.64),
        ]
        let result = try reconcile(tokens, durationMs: 60_000)

        XCTAssertEqual(result.texts, ["Done?!"])
        XCTAssertEqual(result.words[0].endMs, 50_480)
    }

    // MARK: - Timeline preservation

    func testOpeningSilenceAndSourceTimelineAreUntouched() throws {
        // The investigated recording's first word starts at 67.84 s. Restoring
        // durations must not pull anything toward zero or off the far end.
        let tokens = [
            token(" Hello", id: 50, start: 67.84, end: 68.48),
            token(".", id: 7883, start: 68.48, end: 68.56),
            token(" Bye", id: 51, start: 3_486.80, end: 3_487.12),
        ]
        let result = try reconcile(tokens, durationMs: 3_487_171)

        XCTAssertEqual(result.words[0].startMs, 67_840)
        XCTAssertEqual(result.words[0].enclosingStartMs, 67_840)
        XCTAssertEqual(result.words[1].endMs, 3_487_120)
        XCTAssertLessThanOrEqual(result.words[1].enclosingEndMs, 3_487_171)
    }

    // MARK: - Helpers

    private func token(_ text: String, id: Int, start: TimeInterval, end: TimeInterval) -> WorkerTimedToken {
        WorkerTimedToken(text: text, tokenID: id, startSeconds: start, endSeconds: end)
    }

    private func word(_ id: String, _ text: String, start: Int, end: Int) -> RecognizedWord {
        RecognizedWord(
            id: id,
            text: text,
            startMs: start,
            endMs: end,
            enclosingStartMs: min(start, 40_000),
            enclosingEndMs: max(end, 110_000)
        )
    }

    /// Reproduces the pinned v0.12.4 `createTokenTimings` fallback.
    private func endingEachTokenAtTheNextTokensStart(_ tokens: [WorkerTimedToken]) -> [WorkerTimedToken] {
        tokens.enumerated().map { index, token in
            let next = index + 1 < tokens.count ? tokens[index + 1].startSeconds : token.startSeconds + 0.08
            return WorkerTimedToken(
                text: token.text,
                tokenID: token.tokenID,
                startSeconds: token.startSeconds,
                endSeconds: max(next, token.startSeconds + 0.08),
                confidence: token.confidence
            )
        }
    }

    private func reconcile(
        _ tokens: [WorkerTimedToken],
        durationMs: Int
    ) throws -> TokenTimingReconciliationResult {
        try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: WorkerASRTranscript(
                text: "",
                tokens: tokens,
                sourceDurationSeconds: Double(durationMs) / 1_000,
                usedChunkedProcessing: true
            ),
            timeMapping: identityMapping,
            sourceDurationMs: durationMs
        ))
    }

    private func maximumWordDurationMs(_ result: TokenTimingReconciliationResult) -> Int {
        result.words.compactMap { word in
            guard let start = word.startMs, let end = word.endMs else { return nil }
            return end - start
        }.max() ?? 0
    }

    private func longestAdjacentGapMs(_ result: TokenTimingReconciliationResult) -> Int {
        zip(result.words, result.words.dropFirst()).compactMap { current, next in
            guard let end = current.endMs, let start = next.startMs else { return nil }
            return max(0, start - end)
        }.max() ?? 0
    }

    private func speakerIDs(_ built: SpeakerTurnBuildResult) -> [String?] {
        built.segments.map(\.speakerID)
    }
}
