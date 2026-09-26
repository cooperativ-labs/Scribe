import AVFoundation
import ScribeMobile
import XCTest
@testable import ScribeMobileApp

final class MobileDeviceTests: XCTestCase {
    @MainActor
    func testAppStartsWithoutRequestingMicrophoneAccess() throws {
        let before = AVAudioApplication.shared.recordPermission
        let model = try MobileAppModel()
        XCTAssertNil(model.recordingID)
        XCTAssertEqual(AVAudioApplication.shared.recordPermission, before)
        XCTAssertFalse(model.recorder.isRecording)
    }

    /// The optional local model fixtures are staged by Scripts/test-mobile.sh --models.
    /// This is real Core ML on the selected device, never a mock inference backend.
    func testOfflineInferenceOnDevice() async throws {
        let fixtures = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DeviceFixtures", withExtension: nil))
        let sourceModels = fixtures.appending(path: "models")
        guard FileManager.default.fileExists(atPath: sourceModels.path) else {
            throw XCTSkip("Stage the pinned model fixtures with Scripts/test-mobile.sh --models to run device inference.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "scribe-device-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root.appending(path: "meetings"))
        let models = try ModelLibrary(directory: root.appending(path: "models"),
                                      manifestURL: XCTUnwrap(Bundle.main.url(forResource: "model_manifest", withExtension: "json")))
        try await models.install(from: sourceModels)
        let manifest = try await models.validatedManifest()
        let meeting = try await store.create(title: "Device inference test", sourceFilename: "speech.aiff")
        let source = try await store.sourceURL(meeting)
        try FileManager.default.copyItem(at: fixtures.appending(path: "speech.aiff"), to: source)
        let processor = MeetingProcessor(store: store)
        let modelDirectory = await models.directory
        let start = Date()
        try await processor.run(id: meeting.id, inference: LocalMeetingInference(manifest: manifest, models: modelDirectory)) { _ in }
        let complete = try await store.load(meeting.id)
        XCTAssertEqual(complete.state, .complete)
        XCTAssertFalse(complete.turns.isEmpty)
        XCTAssertFalse(complete.speakerIDs.isEmpty)
        XCTAssertTrue(complete.transcriptText.lowercased().contains("meeting"))
        let attachment = XCTAttachment(string: "Device: \(await UIDevice.current.model); audio: \(complete.duration ?? 0)s; total pipeline: \(Date().timeIntervalSince(start))s; turns: \(complete.turns.count); speakers: \(complete.speakerIDs.count)\n\(complete.transcriptText)")
        attachment.name = "Offline inference result"; attachment.lifetime = .keepAlways
        add(attachment)
        // Verify replacing an installed model set is also transactional on the device filesystem.
        try await models.install(from: sourceModels)
        let installed = await models.isInstalled()
        XCTAssertTrue(installed)
    }
}
