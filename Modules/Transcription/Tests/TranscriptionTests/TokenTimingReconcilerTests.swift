import Foundation
import XCTest
@testable import Transcription

final class TokenTimingReconcilerTests: XCTestCase {
    private let reconciler = TokenTimingReconciler()
    private let identityMapping = AudioTimeMapping(sourceSampleRate: 16_000)
    private let targetSuffix = ["The", "weather", "today", "is", "fine."]

    func testPunctuationAttachesWithoutCreatingEmptyWords() throws {
        let result = try reconcile(fixture: "worker-punctuation", durationMs: 2_000)

        XCTAssertEqual(result.texts, ["Hello,", "world!"])
        XCTAssertTrue(result.words.allSatisfy { $0.startMs != nil && $0.endMs != nil })
        XCTAssertTrue(result.words.allSatisfy { word in
            (word.startMs ?? -1) >= 0 && (word.endMs ?? 0) <= 2_000 && (word.startMs ?? 0) < (word.endMs ?? 0)
        })
    }

    func testSentencePieceSubwordsAndNormalizedSpacesFormWords() throws {
        XCTAssertEqual(try reconcile(fixture: "worker-subwords", durationMs: 2_000).texts, ["Hello", "world"])
        XCTAssertEqual(try reconcile(fixture: "worker-normalized-spaces", durationMs: 12_454).texts, ["Hello,", "world!"])
    }

    func testVocabularyResolvesTokenTextAndPunctuationIDs() throws {
        let transcript = WorkerASRTranscript(
            text: "Hi?",
            tokens: [
                WorkerTimedToken(text: "", tokenID: 7, startSeconds: 0.08, endSeconds: 0.4),
                WorkerTimedToken(text: "", tokenID: 7952, startSeconds: 0.4, endSeconds: 0.48),
            ],
            sourceDurationSeconds: 2
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: identityMapping,
            sourceDurationMs: 2_000,
            vocabulary: [7: "\u{2581}Hi", 7952: "?"]
        ))

        XCTAssertEqual(result.texts, ["Hi?"])
        XCTAssertEqual(result.words[0].startMs, 80)
        XCTAssertEqual(result.words[0].endMs, 480)
    }

    func testChunkBoundaryFixturesDropProvenDuplicatesAndKeepEveryUniqueWord() throws {
        let chunked = try reconcile(fixture: "worker-chunk-boundary", durationMs: 40_603)
        let relative = try reconcile(fixture: "worker-chunk-relative", durationMs: 40_603)
        let short = try reconcile(fixture: "worker-english-short", durationMs: 12_454)

        XCTAssertEqual(chunked.texts, ["Please", "wait.", "The", "weather", "today", "is", "fine."])
        XCTAssertEqual(Array(chunked.texts.suffix(from: chunked.texts.count - targetSuffix.count)), targetSuffix)
        XCTAssertEqual(short.texts, targetSuffix)
        XCTAssertEqual(relative.texts, targetSuffix)
        XCTAssertEqual(chunked.droppedDuplicateTokenCount, 5)
        XCTAssertEqual(relative.droppedDuplicateTokenCount, 2)
        try assertNoLostOrDuplicatedChunkWords(fixture: "worker-chunk-boundary", result: chunked)
        try assertNoLostOrDuplicatedChunkWords(fixture: "worker-chunk-relative", result: relative)
        try assertAllWordTimesWithinSource(chunked, durationMs: 40_603)
        try assertAllWordTimesWithinSource(relative, durationMs: 40_603)
    }

    func testAlreadyMergedWorkerOutputIsNotReDuplicated() throws {
        let merged = WorkerASRTranscript(
            text: "Please wait. The weather today is fine.",
            tokens: [
                WorkerTimedToken(text: " Please", tokenID: 10, startSeconds: 1.0, endSeconds: 1.4),
                WorkerTimedToken(text: " wait", tokenID: 11, startSeconds: 1.5, endSeconds: 1.9),
                WorkerTimedToken(text: ".", tokenID: 7883, startSeconds: 1.9, endSeconds: 1.98),
                WorkerTimedToken(text: " The", tokenID: 20, startSeconds: 13.2, endSeconds: 13.5),
                WorkerTimedToken(text: " weather", tokenID: 21, startSeconds: 13.6, endSeconds: 14.0),
                WorkerTimedToken(text: " today", tokenID: 22, startSeconds: 15.0, endSeconds: 15.5),
                WorkerTimedToken(text: " is", tokenID: 23, startSeconds: 26.0, endSeconds: 26.3),
                WorkerTimedToken(text: " fine", tokenID: 24, startSeconds: 26.5, endSeconds: 26.9),
                WorkerTimedToken(text: ".", tokenID: 7883, startSeconds: 26.9, endSeconds: 26.98),
            ],
            sourceDurationSeconds: 40.603,
            usedChunkedProcessing: true
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: merged,
            timeMapping: identityMapping,
            sourceDurationMs: 40_603
        ))

        XCTAssertEqual(result.texts, ["Please", "wait.", "The", "weather", "today", "is", "fine."])
        XCTAssertEqual(result.droppedDuplicateTokenCount, 0)
        try assertAllWordTimesWithinSource(result, durationMs: 40_603)
    }

    func testTimeMappingRestoresSourceRelativeOffsets() throws {
        let mapping = AudioTimeMapping(
            sourceTimelineOffset: 0.5,
            decoderOutputOffset: 0.1,
            sourceSampleRate: 48_000,
            workingSampleRate: 16_000
        )
        let transcript = WorkerASRTranscript(
            text: "Hi",
            tokens: [WorkerTimedToken(text: " Hi", tokenID: 1, startSeconds: 0.2, endSeconds: 0.6)],
            sourceDurationSeconds: 2
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: mapping,
            sourceDurationMs: 2_000
        ))

        XCTAssertEqual(mapping.sourceTime(forWorkingSeconds: 0.2), 0.6, accuracy: 0.000_001)
        XCTAssertEqual(result.words[0].startMs, 600)
        XCTAssertEqual(result.words[0].endMs, 1_000)
    }

    func testInvalidTimingsPreserveTextAsSegmentOnlyAndStayWithinDuration() throws {
        let result = try reconcile(fixture: "worker-invalid-timing", durationMs: 2_000)

        XCTAssertEqual(result.texts, ["Hello", "world"])
        XCTAssertEqual(result.words[0].startMs, 80)
        XCTAssertNil(result.words[1].startMs)
        XCTAssertNil(result.words[1].endMs)
        XCTAssertEqual(result.words[1].enclosingStartMs, 80)
        XCTAssertLessThanOrEqual(result.words[1].enclosingEndMs, 2_000)
        XCTAssertTrue(result.warnings.contains { $0.code == "timing_invalid" })
        try assertAllWordTimesWithinSource(result, durationMs: 2_000)
    }

    func testNoSpeechProducesNoWords() throws {
        let result = try reconcile(fixture: "worker-no-speech", durationMs: 12_454)
        XCTAssertTrue(result.words.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnicodeAndPastOneHourRemainWithinSourceDuration() throws {
        let unicode = try reconcile(fixture: "worker-unicode", durationMs: 13_109)
        let late = try reconcile(fixture: "worker-past-one-hour", durationMs: 3_700_000)

        XCTAssertEqual(unicode.texts, ["Café", "naïve!"])
        XCTAssertEqual(late.texts, ["Still", "speaking."])
        XCTAssertEqual(late.words[0].startMs, 3_600_080)
        try assertAllWordTimesWithinSource(unicode, durationMs: 13_109)
        try assertAllWordTimesWithinSource(late, durationMs: 3_700_000)
    }

    func testUnprovenOverlapUsesMidpointWithoutLosingUniquePrefixOrSuffix() throws {
        let transcript = WorkerASRTranscript(
            text: "alpha omega",
            tokens: [],
            chunks: [
                WorkerASRChunk(chunkIndex: 0, chunkStartSeconds: 0, tokens: [
                    WorkerTimedToken(text: " alpha", tokenID: 1, startSeconds: 1.0, endSeconds: 1.4),
                    WorkerTimedToken(text: " mid", tokenID: 2, startSeconds: 13.0, endSeconds: 13.4),
                ]),
                WorkerASRChunk(chunkIndex: 1, chunkStartSeconds: 12.88, tokens: [
                    WorkerTimedToken(text: " other", tokenID: 9, startSeconds: 13.1, endSeconds: 13.5),
                    WorkerTimedToken(text: " omega", tokenID: 3, startSeconds: 16.0, endSeconds: 16.5),
                ]),
            ],
            sourceDurationSeconds: 20,
            usedChunkedProcessing: true
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: identityMapping,
            sourceDurationMs: 20_000
        ))

        XCTAssertTrue(result.texts.contains("alpha"))
        XCTAssertTrue(result.texts.contains("omega"))
        XCTAssertEqual(result.droppedDuplicateTokenCount, 0)
        try assertAllWordTimesWithinSource(result, durationMs: 20_000)
    }

    func testReconciledWordsFeedSpeakerTurnBuilderWithoutLoss() throws {
        let result = try reconcile(fixture: "worker-chunk-boundary", durationMs: 40_603)
        let turns = result.words.compactMap { word -> DiarizedSpeakerTurn? in
            guard let start = word.startMs, let end = word.endMs else { return nil }
            return DiarizedSpeakerTurn(speakerID: "A", startMs: start, endMs: end)
        }
        let built = try SpeakerTurnBuilder().build(words: result.words, diarizedTurns: turns)

        XCTAssertEqual(Set(built.wordAssignments.map(\.wordID)), Set(result.words.map(\.id)))
        XCTAssertEqual(built.wordAssignments.count, result.words.count)
    }

    func testTimesPastSourceDurationFallBackWithoutEscapingBounds() throws {
        let transcript = WorkerASRTranscript(
            text: "late",
            tokens: [WorkerTimedToken(text: " late", tokenID: 1, startSeconds: 1.8, endSeconds: 2.4)],
            sourceDurationSeconds: 2
        )
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: identityMapping,
            sourceDurationMs: 2_000
        ))

        XCTAssertEqual(result.texts, ["late"])
        XCTAssertNil(result.words[0].startMs)
        XCTAssertLessThanOrEqual(result.words[0].enclosingEndMs, 2_000)
        try assertAllWordTimesWithinSource(result, durationMs: 2_000)
    }

    func testMissingTokensPreserveTranscriptText() throws {
        let transcript = WorkerASRTranscript(text: "Untimed speech.", tokens: [], sourceDurationSeconds: 5)
        let result = try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: transcript,
            timeMapping: identityMapping,
            sourceDurationMs: 5_000
        ))

        XCTAssertEqual(result.texts, ["Untimed speech."])
        XCTAssertNil(result.words[0].startMs)
        XCTAssertEqual(result.warnings.first?.code, "missing_token_timings")
    }

    private func reconcile(fixture name: String, durationMs: Int) throws -> TokenTimingReconciliationResult {
        try reconciler.reconcile(TokenTimingReconciliationRequest(
            workerTranscript: try loadWorkerFixture(name),
            timeMapping: identityMapping,
            sourceDurationMs: durationMs
        ))
    }

    private func loadWorkerFixture(_ name: String) throws -> WorkerASRTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try WorkerASRTranscriptCodec.decode(Data(contentsOf: url))
    }

    private func assertAllWordTimesWithinSource(
        _ result: TokenTimingReconciliationResult,
        durationMs: Int
    ) throws {
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.enclosingStartMs, 0, word.id)
            XCTAssertLessThanOrEqual(word.enclosingEndMs, durationMs, word.id)
            XCTAssertLessThan(word.enclosingStartMs, word.enclosingEndMs, word.id)
            guard let start = word.startMs, let end = word.endMs else { continue }
            XCTAssertGreaterThanOrEqual(start, 0, word.id)
            XCTAssertLessThan(start, end, word.id)
            XCTAssertLessThanOrEqual(end, durationMs, word.id)
            XCTAssertGreaterThanOrEqual(start, word.enclosingStartMs, word.id)
            XCTAssertLessThanOrEqual(end, word.enclosingEndMs, word.id)
        }
    }

    private func assertNoLostOrDuplicatedChunkWords(
        fixture name: String,
        result: TokenTimingReconciliationResult
    ) throws {
        let transcript = try loadWorkerFixture(name)
        let chunks = try XCTUnwrap(transcript.chunks)
        let expected = try TokenTimingReconciler().reconcile(TokenTimingReconciliationRequest(
            workerTranscript: WorkerASRTranscript(
                text: transcript.text,
                tokens: uniqueTokens(from: chunks),
                sourceDurationSeconds: transcript.sourceDurationSeconds,
                usedChunkedProcessing: false
            ),
            timeMapping: identityMapping,
            sourceDurationMs: milliseconds(transcript.sourceDurationSeconds)
        ))
        XCTAssertEqual(result.texts, expected.texts)
    }

    private func uniqueTokens(from chunks: [WorkerASRChunk]) -> [WorkerTimedToken] {
        var seen = Set<String>()
        var tokens: [WorkerTimedToken] = []
        for chunk in chunks.sorted(by: { $0.chunkIndex < $1.chunkIndex }) {
            for token in chunk.tokens {
                let offset = chunk.timesAreAbsolute ? 0 : chunk.chunkStartSeconds
                let absolute = WorkerTimedToken(
                    text: token.text,
                    tokenID: token.tokenID,
                    startSeconds: token.startSeconds + offset,
                    endSeconds: token.endSeconds + offset,
                    confidence: token.confidence
                )
                let key = "\(absolute.tokenID)|\(absolute.text)|\(String(format: "%.3f", absolute.startSeconds))"
                if seen.insert(key).inserted {
                    tokens.append(absolute)
                }
            }
        }
        return tokens
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }
}
