import FluidAudio
import Foundation
import Testing
@testable import ScribeInference

struct OfflineVocabularyTests {
    private func token(_ text: String, _ start: Double, _ end: Double) -> TokenTiming {
        .init(token: text, tokenId: 1, startTime: start, endTime: end, confidence: 1)
    }
    @Test func repeatedPhraseIsCorrectedAtTheAudioOccurrence() {
        let text = "Liv Mali. Liv Mali!"
        let tokens = [token("▁Liv", 0, 0.2), token("▁Mali", 0.2, 0.4), token(".", 0.4, 0.5),
                      token("▁Liv", 31, 31.2), token("▁Mali", 31.2, 31.4), token("!", 31.4, 31.5)]
        let replacement = VocabularyReplacement(original: "Liv Mali!", replacement: "Livmarli", startSeconds: 31, endSeconds: 31.5, originalScore: -3, replacementScore: -2)
        #expect(OfflineVocabularyRescorer.correctedText(text, tokens: tokens, replacements: [replacement]) == "Liv Mali. Livmarli!")
    }
    @Test func emptyAndTooShortVocabularyNeverAccessModelsOrAudio() async throws {
        let manifest = try ModelManifest.load(from: repository.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        for snapshot in [WorkerVocabularySnapshot(), .init(terms: [.init(text: "AI")]), .init(terms: [.init(text: "...")])] {
            let result = await OfflineVocabularyRescorer.rescore(fileURL: URL(fileURLWithPath: "/missing.wav"), text: "normal speech", tokens: [], snapshot: snapshot, manifest: manifest, modelsDirectory: URL(fileURLWithPath: "/missing-models"))
            #expect(result.text == "normal speech")
            #expect(result.warning == nil)
            #expect(result.replacements.isEmpty)
        }
    }
    @Test func missingOptionalAssetsReturnRawTextAndStructuredWarning() async throws {
        let manifest = try ModelManifest.load(from: repository.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        let result = await OfflineVocabularyRescorer.rescore(fileURL: URL(fileURLWithPath: "/missing.wav"), text: "normal speech", tokens: [], snapshot: .init(terms: [.init(text: "NVIDIA")]), manifest: manifest, modelsDirectory: URL(fileURLWithPath: "/missing-models"))
        #expect(result.text == "normal speech")
        #expect(result.warning == "vocabulary_assets_unavailable")
        #expect(result.replacements.isEmpty)
    }
    @Test func exactSpellingNeedsAudioEvidenceAndKeepsNeighboringWords() {
        let tokens = [token("▁clear", 1, 1.3), token("▁comply", 1.3, 1.6), token("▁works", 1.6, 1.9)]
        #expect(OfflineVocabularyRescorer.exactSpellings(tokens: tokens, detections: [], minimumScore: -12).isEmpty)
        let detection = CtcKeywordSpotter.KeywordDetection(term: .init(text: "Clear Comply"), score: -7, totalFrames: 25,
            startFrame: 12, endFrame: 20, startTime: 1, endTime: 1.6)
        let replacements = OfflineVocabularyRescorer.exactSpellings(tokens: tokens, detections: [detection], minimumScore: -12)
        #expect(replacements.count == 1)
        #expect(replacements.first?.original == "clear comply")
        #expect(OfflineVocabularyRescorer.correctedText("clear comply works", tokens: tokens, replacements: replacements) == "Clear Comply works")
        #expect(OfflineVocabularyRescorer.exactSpellings(tokens: tokens, detections: [detection], minimumScore: -5).isEmpty)
    }
    @Test func vocabularyNeverConsumesCorrectNeighbors() {
        #expect(!OfflineVocabularyRescorer.accepts(original: "clear comply works", canonical: "Clear Comply", aliases: ["clear comply"], similarity: 0.8))
        #expect(!OfflineVocabularyRescorer.accepts(original: "ordinary speech", canonical: "NVIDIA", aliases: [], similarity: 0.2))
        #expect(OfflineVocabularyRescorer.accepts(original: "Liv Mali", canonical: "Livmarli", aliases: ["Liv Mali"], similarity: 1))
    }
    @Test func snapshotRequiresRunLocalArtifact() throws {
        #expect(throws: (any Error).self) { try WorkerVocabularySnapshot.load(in: repository, path: "../library.json") }
    }
    @Test func optionalValidationSeparatesBaseReadinessAndDetectsCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shipping = try Data(contentsOf: repository.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        var object = try #require(JSONSerialization.jsonObject(with: shipping) as? [String: Any])
        var asset = try #require((object["assets"] as? [[String: Any]])?.first { $0["id"] as? String == "parakeet-ctc-110m" })
        asset["requiredFiles"] = [["relativePath": "tokenizer.json", "bytes": 3, "sha256": String(repeating: "0", count: 64)]]
        object["assets"] = [asset]
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(manifest.validate(modelsDirectory: directory).isValid)
        #expect(!manifest.validate(modelsDirectory: directory, assetID: "parakeet-ctc-110m").isValid)
        let ctc = directory.appendingPathComponent("parakeet-ctc-110m-coreml")
        try FileManager.default.createDirectory(at: ctc, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: ctc.appendingPathComponent("tokenizer.json"))
        #expect(manifest.validate(modelsDirectory: directory).isValid)
        #expect(manifest.validate(modelsDirectory: directory, assetID: "parakeet-ctc-110m").failures.contains { $0.reason == "SHA-256 mismatch" })
    }
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
