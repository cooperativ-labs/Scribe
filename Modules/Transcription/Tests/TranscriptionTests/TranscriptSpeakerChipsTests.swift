import CoreGraphics
import Speakers
import XCTest
@testable import Transcription

final class TranscriptSpeakerChipsTests: XCTestCase {
    private let dana = SpeakerPersonRef(profileID: UUID(), displayName: "Dana Whitfield")

    func testSuggestionBadgeShowsNameAndWholePercentage() {
        let suggestion = TranscriptSpeakerSuggestion(speakerID: "speaker_3", person: dana, score: 0.824, matcherVersion: "test")

        XCTAssertEqual(suggestion.percentDescription, "82%")
        XCTAssertEqual(suggestion.chipBadgeTitle, "Dana Whitfield? 82%")
        XCTAssertEqual(suggestion.scoreDescription, "similarity 0.82", "the hover text keeps the raw similarity")
    }

    func testSuggestionPercentageIsClampedToTheUnitRange() {
        XCTAssertEqual(TranscriptSpeakerSuggestion(speakerID: "a", person: dana, score: 1.3, matcherVersion: "t").percentDescription, "100%")
        XCTAssertEqual(TranscriptSpeakerSuggestion(speakerID: "a", person: dana, score: -0.2, matcherVersion: "t").percentDescription, "0%")
    }

    func testFewChipsStayOnOneLineAtTheAvailableWidth() {
        let arrangement = arrange(count: 3, chipWidth: 100, targetWidth: 600)

        XCTAssertEqual(arrangement.lineCount, 1)
        XCTAssertEqual(arrangement.size.width, 100 * 3 + 6 * 2)
        XCTAssertEqual(arrangement.size.height, 28)
    }

    func testChipsWrapAtTheAvailableWidth() {
        let arrangement = arrange(count: 5, chipWidth: 100, targetWidth: 320)

        XCTAssertEqual(arrangement.lineCount, 2)
        XCTAssertEqual(arrangement.origins.map(\.y), [0, 0, 0, 34, 34])
        XCTAssertLessThanOrEqual(arrangement.size.width, 320)
    }

    func testManyChipsWidenInsteadOfPassingThreeLines() {
        let arrangement = arrange(count: 20, chipWidth: 100, targetWidth: 320)

        XCTAssertEqual(arrangement.lineCount, 3, "the row stops at three lines")
        XCTAssertEqual(arrangement.size.height, 28 * 3 + 6 * 2)
        XCTAssertGreaterThan(arrangement.size.width, 320, "wider than the window, so the row scrolls horizontally")
    }

    func testEmptyRowHasNoSize() {
        XCTAssertEqual(arrange(count: 0, chipWidth: 100, targetWidth: 320).size, .zero)
    }

    func testZeroWidthBeforeMeasurementStillFitsThreeLines() {
        let arrangement = arrange(count: 7, chipWidth: 90, targetWidth: 0)

        XCTAssertLessThanOrEqual(arrangement.lineCount, 3)
        XCTAssertEqual(arrangement.origins.count, 7)
    }

    private func arrange(count: Int, chipWidth: CGFloat, targetWidth: CGFloat) -> TranscriptChipFlowLayout.Arrangement {
        TranscriptChipFlowLayout.arrange(
            sizes: Array(repeating: CGSize(width: chipWidth, height: 28), count: count),
            targetWidth: targetWidth,
            spacing: 6,
            maxLines: 3
        )
    }
}
