import AVFoundation
import Foundation
import ScribeInference
import Testing
@testable import ScribeMobile

private func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "scribe-mobile-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func privateStorageRecoversInterruptedWorkAndRejectsTraversal() async throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(root: root)
    let meeting = try await store.create(title: "Interrupted", sourceFilename: "recording.caf", state: .recording)
    let recovered = try await store.list(recoverInterrupted: true)
    #expect(recovered.first?.id == meeting.id)
    #expect(recovered.first?.state == .paused)
    #expect(recovered.first?.notice?.contains("interrupted") == true)
    #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    await #expect(throws: MobileError.self) {
        try await store.create(title: "Unsafe", sourceFilename: "../outside.caf")
    }
    try await store.delete(meeting.id)
    #expect(try await store.list().isEmpty)
}

@Test func transcriptExportOmitsLocalAudioAndKeepsSpeakerNames() {
    var meeting = Meeting(title: "Weekly meeting", sourceFilename: "SECRET_AUDIO.caf")
    meeting.turns = [Turn(start: 10, end: 12, text: "A decision.", speakerID: "speaker_1")]
    meeting.speakerNames = ["speaker_1": "Sam"]
    #expect(meeting.transcriptText.contains("[00:10] Sam: A decision."))
    #expect(!meeting.transcriptText.contains("SECRET_AUDIO"))
}

private func transcript() throws -> ParakeetAdapter.Transcript {
    try JSONDecoder().decode(ParakeetAdapter.Transcript.self, from: Data("""
    {"text":"Hello world","tokens":[
      {"text":" Hello","tokenID":1,"startSeconds":0,"endSeconds":0.4,"confidence":0.9},
      {"text":" world","tokenID":2,"startSeconds":0.4,"endSeconds":0.8,"confidence":0.9}],
     "sourceDurationSeconds":1,"processingTimeSeconds":0.1,"usedChunkedProcessing":false,"timestampUnit":"seconds"}
    """.utf8))
}
private func diarization(overlap: Bool = false) throws -> OfflineDiarizationAdapter.Result {
    let extra = overlap ? ",{\"speakerID\":\"speaker_2\",\"startSeconds\":0,\"endSeconds\":1,\"qualityScore\":0.9,\"overlapsAnotherSpeaker\":true}" : ""
    return try JSONDecoder().decode(OfflineDiarizationAdapter.Result.self, from: Data("""
    {"intervals":[{"speakerID":"speaker_1","startSeconds":0,"endSeconds":1,"qualityScore":0.9,"overlapsAnotherSpeaker":false}\(extra)],
     "embeddings":[],"sourceDurationSeconds":1,"usedDiskBackedAudio":true,
     "engine":{"runtime":"test","runtimeRevision":"test","modelRevision":"test"},
     "configuration":{"minimumGapDurationSeconds":0.1,"minimumSegmentDurationSeconds":0,"clusteringThreshold":0.6,"embeddingExcludeOverlap":true,"minimumEmbeddingDurationSeconds":1,"segmentationStepRatio":0.2,"preserveOverlappingIntervals":true,"constrainedAssignment":true,"warmStartFa":0.07,"warmStartFb":0.8,"maximumVBxIterations":20},
     "clusteringDiagnostics":{"heuristicVersion":"test","embeddingCount":0,"intervalCount":1,"overlapIntervalCount":0,"occupancies":[],"separationAppearsCollapsed":false}}
    """.utf8))
}

@Test func attributionPreservesUnknownOverlappingSpeech() throws {
    let single = MeetingProcessor.assemble(transcript: try transcript(), diarization: try diarization())
    #expect(single.count == 1)
    #expect(single.first?.text == "Hello world")
    #expect(single.first?.speakerID == "speaker_1")
    let overlap = MeetingProcessor.assemble(transcript: try transcript(), diarization: try diarization(overlap: true))
    #expect(overlap.first?.speakerID == nil)
    #expect(overlap.first?.overlaps == true)
}

private func makeAudio(at url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for channel in 0..<2 {
        for sample in 0..<48_000 { buffer.floatChannelData![channel][sample] = Float(sin(Double(sample) * 0.05)) * 0.1 }
    }
    try file.write(from: buffer)
}

@Test func decoderConvertsStereoToSixteenKilohertzMono() async throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.caf"), destination = root.appending(path: "prepared.caf")
    try makeAudio(at: source)
    let duration = try await AudioPreparation.prepare(source: source, destination: destination)
    let decoded = try AVAudioFile(forReading: destination)
    #expect(abs(duration - 1) < 0.02)
    #expect(decoded.processingFormat.sampleRate == 16_000)
    #expect(decoded.processingFormat.channelCount == 1)
}

private actor CancellingInference: MeetingInference {
    var transcriptions = 0
    var diarizations = 0
    func transcribe(_ source: URL) throws -> ParakeetAdapter.Transcript {
        transcriptions += 1; return try transcript()
    }
    func diarize(_ source: URL) throws -> OfflineDiarizationAdapter.Result {
        diarizations += 1
        if diarizations == 1 { throw CancellationError() }
        return try diarization()
    }
}

@Test func processingResumesAfterCancellationWithoutRepeatingASR() async throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(root: root)
    let meeting = try await store.create(title: "Resume", sourceFilename: "source.caf")
    try await makeAudio(at: store.sourceURL(meeting))
    let inference = CancellingInference()
    let processor = MeetingProcessor(store: store)
    await #expect(throws: CancellationError.self) { try await processor.run(id: meeting.id, inference: inference) { _ in } }
    #expect(try await store.load(meeting.id).state == .paused)
    #expect(await store.exists(id: meeting.id, name: "asr.json"))
    try await processor.run(id: meeting.id, inference: inference) { _ in }
    #expect(try await store.load(meeting.id).state == .complete)
    #expect(await inference.transcriptions == 1)
    #expect(await inference.diarizations == 2)
    #expect(!(await store.exists(id: meeting.id, name: "prepared.caf")))
}

@Test func modelInstallationVerifiesEveryFileAndPreservesPriorInstall() async throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source")
    try FileManager.default.createDirectory(at: source.appending(path: "asset"), withIntermediateDirectories: true)
    let payload = source.appending(path: "asset/weights.bin")
    try Data("abc".utf8).write(to: payload)
    let manifest = root.appending(path: "manifest.json")
    try Data("""
    {"schemaVersion":1,"profileID":"test","fluidAudio":{"repository":"test","revision":"test"},
     "telemetry":{"enabled":false,"runtimeDownloadsAllowed":false},"totalDeclaredOnDiskBytes":3,
     "assets":[{"id":"test","relativePath":"asset","upstream":{"repository":"test","revision":"test"},
       "checksum":{"algorithm":"sha256","value":"test","scope":"test"},"license":"test",
       "requiredFiles":[{"relativePath":"weights.bin","bytes":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]}]}
    """.utf8).write(to: manifest)
    let library = try ModelLibrary(directory: root.appending(path: "installed"), manifestURL: manifest)
    try await library.install(from: source)
    #expect(await library.isInstalled())
    try await library.install(from: source)
    #expect(await library.isInstalled())
    try Data("bad".utf8).write(to: payload)
    await #expect(throws: MobileError.self) { try await library.install(from: source) }
    #expect(await library.isInstalled())
}

@Test func interruptedImportCannotAppearReady() async throws {
    let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(root: root)
    _ = try await store.create(title: "Incomplete copy", sourceFilename: "source.m4a", state: .importing)
    let recovered = try await store.list(recoverInterrupted: true)
    #expect(recovered.first?.state == .failed)
    #expect(recovered.first?.notice?.contains("import") == true)
}

@Test func trailingPunctuationDoesNotCreateAnUnknownSpeaker() throws {
    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript())) as! [String: Any]
    var modified = original
    var tokens = modified["tokens"] as! [[String: Any]]
    tokens.append(["text": ".", "tokenID": 3, "startSeconds": 1.0, "endSeconds": 1.1, "confidence": 0.9])
    modified["tokens"] = tokens
    let asr = try JSONDecoder().decode(ParakeetAdapter.Transcript.self, from: JSONSerialization.data(withJSONObject: modified))
    let turns = MeetingProcessor.assemble(transcript: asr, diarization: try diarization())
    #expect(turns.count == 1)
    #expect(turns.first?.speakerID == "speaker_1")
    #expect(turns.first?.text == "Hello world.")
}
