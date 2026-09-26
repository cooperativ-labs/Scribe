import Foundation
import Speakers
import SwiftUI
import XCTest
@testable import Transcription

final class TranscriptDesignPaletteTests: XCTestCase {

    func testSpeakersAreColouredInRecordingOrderStartingBlueTealOrangePurple() {
        let palette = TranscriptDesign.SpeakerPalette(speakerIDs: ["speaker_1", "speaker_2", "speaker_3", "speaker_4"])

        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_1"), .blue)
        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_2"), .teal)
        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_3"), .orange)
        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_4"), .purple)
    }

    func testThePaletteIsDeterministicForTheSameSpeakerTable() {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        let first = TranscriptDesign.SpeakerPalette(speakerIDs: ids)
        let second = TranscriptDesign.SpeakerPalette(speakerIDs: ids)

        XCTAssertEqual(first, second)
        XCTAssertEqual(ids.map { first.swatch(forSpeakerID: $0) }, ids.map { second.swatch(forSpeakerID: $0) })
    }

    func testColoursDependOnPositionNotOnTheIDItself() {
        // The same ID in a different slot gets that slot's colour: the colour
        // belongs to the recording's speaker order, not to the string.
        XCTAssertEqual(TranscriptDesign.SpeakerPalette(speakerIDs: ["x", "y"]).swatch(forSpeakerID: "y"), .teal)
        XCTAssertEqual(TranscriptDesign.SpeakerPalette(speakerIDs: ["y", "x"]).swatch(forSpeakerID: "y"), .blue)
    }

    func testTheSetRepeatsAfterItIsUsedUp() {
        let count = TranscriptDesign.SpeakerSwatch.allCases.count
        let ids = (0..<(count * 2 + 1)).map { "speaker_\($0)" }
        let palette = TranscriptDesign.SpeakerPalette(speakerIDs: ids)

        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_\(count)"), .blue)
        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_\(count + 1)"), .teal)
        XCTAssertEqual(palette.swatch(forSpeakerID: "speaker_\(count * 2)"), .blue)
        XCTAssertEqual(TranscriptDesign.SpeakerSwatch.at(index: -1), .brown)
    }

    func testUnknownSpeakersHaveNoColour() {
        let palette = TranscriptDesign.SpeakerPalette(speakerIDs: ["speaker_1"])

        XCTAssertNil(palette.swatch(forSpeakerID: nil))
        XCTAssertNil(palette.swatch(forSpeakerID: "speaker_99"))
        XCTAssertNil(palette.color(forSpeakerID: nil))
        XCTAssertNil(TranscriptDesign.SpeakerPalette.empty.swatch(forSpeakerID: "speaker_1"))
    }

    func testDuplicateIDsKeepTheirFirstSlot() {
        let palette = TranscriptDesign.SpeakerPalette(speakerIDs: ["a", "a", "b"])

        XCTAssertEqual(palette.count, 2)
        XCTAssertEqual(palette.swatch(forSpeakerID: "a"), .blue)
        XCTAssertEqual(palette.swatch(forSpeakerID: "b"), .orange)
    }

    func testReviewFlagsUseOrangeForUncertainAndRedForOverlap() {
        XCTAssertEqual(TranscriptDesign.ReviewFlag.uncertain.color, .orange)
        XCTAssertEqual(TranscriptDesign.ReviewFlag.overlap.color, .red)
    }

    func testTurnTypeRoleMatchesTheProposal() {
        XCTAssertEqual(TranscriptDesign.TypeRole.turnFontSize, 14.5)
        XCTAssertEqual(TranscriptDesign.TypeRole.turnLineHeightMultiple, 1.55)
        XCTAssertEqual(TranscriptDesign.Spacing.rowCornerRadius, 10)
        XCTAssertEqual(TranscriptDesign.Surface.chip, .capsule)
        XCTAssertEqual(TranscriptDesign.Surface.transport, .capsule)
        XCTAssertEqual(TranscriptDesign.Surface.hoverPill, .capsule)
    }
}

@MainActor
final class TranscriptViewModelPaletteTests: XCTestCase {

    func testTheViewModelColoursSpeakersByTableOrder() throws {
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: snapshotURL, transcript: try fixture(named: "four-speakers"), jobState: .complete)],
            playback: PlaybackStub()
        )

        XCTAssertEqual(viewModel.speakerPalette.count, 4)
        XCTAssertEqual(viewModel.speakerSwatch(forSpeakerID: "speaker_1"), .blue)
        XCTAssertEqual(viewModel.speakerSwatch(forSpeakerID: "speaker_3"), .orange)
        XCTAssertEqual(viewModel.color(forSpeakerID: "speaker_4"), Color.purple)
        XCTAssertNil(viewModel.color(forSpeakerID: nil))
    }

    func testAnUnknownSpeakerTurnHasNoColour() throws {
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: snapshotURL, transcript: try fixture(named: "unknown-speaker"), jobState: .complete)],
            playback: PlaybackStub()
        )
        let segment = try XCTUnwrap(viewModel.chronologicalSegments.first)

        XCTAssertNil(segment.speakerID)
        XCTAssertNil(viewModel.speakerSwatch(forSpeakerID: segment.speakerID))
    }

    func testColoursSurviveRenamingASpeaker() throws {
        let viewModel = TranscriptViewModel(
            files: [TranscriptReviewFile(sourceSnapshotURL: snapshotURL, transcript: try fixture(named: "two-speakers"), jobState: .complete)],
            playback: PlaybackStub()
        )
        let before = viewModel.recordingSpeakers.map { viewModel.speakerSwatch(forSpeakerID: $0.id) }
        XCTAssertEqual(before, [.blue, .teal])
        XCTAssertEqual(viewModel.speakerRows.map(\.label), ["Alex", "Speaker 2"])

        let dana = SpeakerPersonRef(profileID: UUID(), displayName: "Dana Whitfield")
        viewModel.assign(dana, scope: .cluster(speakerID: "speaker_2"))
        XCTAssertEqual(viewModel.speakerRows.map(\.label), ["Alex", "Dana Whitfield"])

        XCTAssertEqual(viewModel.recordingSpeakers.map { viewModel.speakerSwatch(forSpeakerID: $0.id) }, before)

        viewModel.assign(nil, scope: .cluster(speakerID: "speaker_1"))
        XCTAssertNotEqual(viewModel.speakerRows.first?.label, "Alex")
        XCTAssertEqual(viewModel.speakerSwatch(forSpeakerID: "speaker_1"), .blue)

        viewModel.undo()
        viewModel.undo()
        XCTAssertEqual(viewModel.speakerRows.map(\.label), ["Alex", "Speaker 2"])
        XCTAssertEqual(viewModel.recordingSpeakers.map { viewModel.speakerSwatch(forSpeakerID: $0.id) }, before)
    }

    private var snapshotURL: URL { URL(fileURLWithPath: "/tmp/scribe-design-snapshot.flac") }

    private func fixture(named name: String) throws -> CanonicalTranscript {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try CanonicalTranscriptCodec.decode(Data(contentsOf: url))
    }
}

private final class PlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL: URL) {}
    func seek(toMilliseconds milliseconds: Int) {}
    func play() {}
    func pause() {}
    func setRate(_ rate: Float) {}
    func setPlaybackObserver(_ observer: (@MainActor (TranscriptPlaybackEvent) -> Void)?) {}
}
