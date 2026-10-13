// Diagnostic probe; run from the repository root after building the Release worker.
// The sole argument is a directory containing audio.wav and vocabulary.json.
// Measures setup and keyword spotting only, not candidate rescoring or final text.
// Compile/link instructions: docs/investigations/vocabulary-transcription-latency.md.
@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import ScribeInference

@main struct Stages {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appendingPathComponent("Workers/TranscriptionWorker/models")
        let ctcDirectory = directory.appendingPathComponent("parakeet-ctc-110m-coreml")
        let manifest = try ModelManifest.load(from: root.appendingPathComponent("Workers/TranscriptionWorker/model_manifest.json"))
        let snapshot = try JSONDecoder().decode(WorkerVocabularySnapshot.self, from: Data(contentsOf: work.appendingPathComponent("vocabulary.json")))
        let file = try AVAudioFile(forReading: work.appendingPathComponent("audio.wav"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        var rows: [[String: Any]] = []
        func measure(_ label: String, _ start: ContinuousClock.Instant) {
            let c = start.duration(to: .now).components
            let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
            let row: [String: Any] = ["label": label, "wallSeconds": seconds]
            rows.append(row)
            print(String(data: try! JSONSerialization.data(withJSONObject: row, options: .sortedKeys), encoding: .utf8)!)
            fflush(stdout)
        }
        for pass in 1...3 {
            var start = ContinuousClock.now
            let report = manifest.validate(modelsDirectory: directory, assetID: "parakeet-ctc-110m")
            guard report.isValid else { fatalError("invalid model") }
            measure("\(pass)-validate", start)
            start = .now
            let models = try await CtcModels.loadDirect(from: ctcDirectory, variant: .ctc110m)
            measure("\(pass)-loadModels", start)
            start = .now
            let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
            let terms = snapshot.usableTerms.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases, ctcTokenIds: tokenizer.encode($0.text)) }
            let context = CustomVocabularyContext(terms: terms)
            let spotter = CtcKeywordSpotter(models: models)
            let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: context, config: .init(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false), ctcModelDirectory: ctcDirectory)
            _ = rescorer
            measure("\(pass)-tokenizersAndContext", start)
            for inference in 1...2 {
                start = .now
                let result = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context)
                measure("\(pass)-spotKeywords-\(inference)", start)
                guard !result.logProbs.isEmpty else { fatalError("no probabilities") }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: work.appendingPathComponent("stages.json"))
    }
}
