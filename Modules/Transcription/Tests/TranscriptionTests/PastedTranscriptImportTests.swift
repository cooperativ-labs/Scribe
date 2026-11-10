import Foundation
import XCTest
@testable import Transcription

final class PastedTranscriptImportTests: XCTestCase {
    private let sample = """
    Mary Laut (01:35): Waiting.

    Akira Nesfield (01:36): For B. Right. Yes.

    Wissam Akra (01:40): Jennifer. Oh, I think. I think we might have. No,.

    LaToya Campbell (01:46): We have one more person. Yeah. Yeah,.

    Wissam Akra (01:50): Bianca. And do we know if Mary's.

    Wissam Akra (01:54): Joining? She has. She's here. Oh, here she is. Yes. Hi. Hello. Hello. Well,.

    Wissam Akra (02:04): Good afternoon and thank you for taking a call at lunch.

    Jennifer Fraticelli (02:41): My name is Jennifer Fraticelli.

    Juri Gerena (03:20): Good morning, everyone.

    Mary Laut (04:03): I'm Gerda and I'm also a WCD coordinator.
    """

    func testFirefliesPreservesLabelsTextAndSourceRelativeStarts() throws {
        let transcript = try PastedTranscriptParser.parse(sample, format: .fireflies, title: "  Introductions  ")
        XCTAssertEqual(transcript.title, "Introductions")
        XCTAssertEqual(transcript.segments.count, 10)
        XCTAssertEqual(transcript.speakers.count, 6)
        XCTAssertEqual(transcript.segments.first?.startMs, 95_000)
        XCTAssertEqual(transcript.segments.last?.startMs, 243_000)
        // The source label wins even when spoken text introduces another name.
        XCTAssertEqual(transcript.segments.last?.speakerID, transcript.segments.first?.speakerID)
        XCTAssertEqual(transcript.segments[2].text, "Jennifer. Oh, I think. I think we might have. No,.")
        XCTAssertEqual(transcript.status, .completeWithWarnings)
        XCTAssertTrue(transcript.segments.allSatisfy { $0.words == nil && $0.timingQuality == .segmentOnly })
        for format in TranscriptExportFormat.allCases {
            XCTAssertFalse(try TranscriptExporter.export(transcript, as: format).isEmpty)
        }
        let json = try TranscriptExporter.export(transcript, as: .json)
        XCTAssertEqual(try CanonicalTranscriptCodec.decode(json), transcript)
    }

    func testWrappedUnicodeTextHourTimestampsAndSimultaneousTurns() throws {
        let transcript = try PastedTranscriptParser.parse("Zoë (01:02:03): Hello\r\nwrapped text.\r\n李 (01:02:03): Hi", format: .fireflies, title: "Meeting")
        XCTAssertEqual(transcript.segments[0].text, "Hello\nwrapped text.")
        XCTAssertEqual(transcript.segments[0].startMs, 3_723_000)
        XCTAssertEqual(transcript.segments[1].speakerLabel, "李")
        try CanonicalTranscriptValidator.validate(transcript)
    }

    func testInvalidInputIsRejectedWithoutWritingPartialMeetings() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = StoredPastedTranscriptImporter(store: TranscriptStore(storeDirectoryURL: root))
        for text in ["", "Just text", "A (01:60): Invalid", "A (02:00): First\nB (01:00): Earlier", "A (00:00):", "A (00:00): First\nB (bad): Lost"] {
            XCTAssertThrowsError(try importer.importTranscript(text, format: .fireflies, title: "Meeting"), text)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testImportPersistsReloadsSelectsAndRoutesToAgentWithoutAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(storeDirectoryURL: root)
        let dispatcher = ImportAgentSpy()
        let model = TranscriptViewModel(files: [], playback: ImportPlaybackStub(),
                                        pastedTranscriptImporter: StoredPastedTranscriptImporter(store: store), agentDispatcher: dispatcher)
        try model.importPastedTranscript(sample, format: .fireflies, title: "Introductions")
        let imported = try XCTUnwrap(model.selectedFile)
        XCTAssertFalse(imported.hasAudio)
        XCTAssertFalse(model.canRetranscribe(imported))
        let reloaded = TranscriptStore(storeDirectoryURL: root).latestRunPerSource().map(TranscriptReviewFile.init)
        XCTAssertEqual(reloaded, [imported])
        XCTAssertEqual(try store.confinedCompletedRuns().runs.count, 1)
        model.reload(files: reloaded)
        await model.loadAgentEnvironment()
        XCTAssertTrue(model.canSubmitAgentHandoff)
        let sent = await model.sendToAgent()
        XCTAssertTrue(sent)
        XCTAssertEqual(dispatcher.request?.transcript, imported.transcript)
        try store.deleteMeeting(containingRunID: UUID(uuidString: imported.id)!)
        XCTAssertTrue(store.runs().isEmpty)
    }
}

private final class ImportPlaybackStub: TranscriptPlaybackSeeking {
    func load(sourceSnapshotURL: URL) {}
    func seek(toMilliseconds: Int) {}
}

private final class ImportAgentSpy: TranscriptAgentDispatching, @unchecked Sendable {
    var request: TranscriptAgentRequest?
    func environment() async -> TranscriptAgentEnvironment {
        TranscriptAgentEnvironment(agents: [TranscriptAgent(id: "codex", displayName: "Codex", commandLabel: "codex")])
    }
    func connectFolder() async -> TranscriptAgentEnvironment { await environment() }
    func disconnectFolder(id: String) async -> TranscriptAgentEnvironment { await environment() }
    func send(_ request: TranscriptAgentRequest) async -> TranscriptAgentOutcome {
        self.request = request
        return TranscriptAgentOutcome(sessionName: "import-test", agentName: "Codex", folderName: nil)
    }
}
