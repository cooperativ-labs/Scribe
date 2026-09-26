import XCTest
@testable import Transcription

final class TranscriptRowReviewTests: XCTestCase {
    func testOverlapTakesVisualPriorityButHelpRetainsEveryReason() {
        let turn = TranscriptSegment(
            id: "turn", speakerID: "speaker_1", speakerLabel: "Dana", startMs: 0, endMs: 1_000,
            text: "Hello", overlap: true, timingQuality: .segmentOnly, speakerConfidence: 0.43
        )

        XCTAssertEqual(TranscriptRowReview.flag(for: turn), .overlap)
        XCTAssertEqual(TranscriptRowReview.description(for: turn),
                       "Uncertain speaker (43%), Overlapping speech, Estimated timing")
    }

    func testCleanTurnHasNoDotOrReviewDescription() {
        let turn = TranscriptSegment(
            id: "turn", speakerID: "speaker_1", speakerLabel: "Dana", startMs: 0, endMs: 1_000,
            text: "Hello", overlap: false, timingQuality: .asrWord
        )

        XCTAssertNil(TranscriptRowReview.flag(for: turn))
        XCTAssertEqual(TranscriptRowReview.description(for: turn), "")
    }

    func testParagraphHidesSegmentCountInDotHelp() {
        let paragraph = TranscriptParagraph(
            id: "paragraph", speakerID: "speaker_1", speakerLabel: "Dana", startMs: 0, endMs: 2_000,
            text: "Hello again", overlap: false, timingQuality: .asrWord,
            speakerConfidence: nil, words: nil, sourceSegmentIDs: ["one", "two"]
        )

        XCTAssertEqual(TranscriptRowReview.flag(for: paragraph), .uncertain)
        XCTAssertEqual(TranscriptRowReview.description(for: paragraph), "2 segments")
    }
}
