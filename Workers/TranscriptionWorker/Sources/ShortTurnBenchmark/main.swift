import Foundation
import TranscriptionWorkerSupport

@main
struct ShortTurnBenchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else {
            throw NSError(domain: "Usage: ShortTurnBenchmark AUDIO MANIFEST MODELS NEW_OUTPUT_DIRECTORY", code: 1)
        }
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw NSError(domain: "Output already exists", code: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let manifest = try ModelManifest.load(from: URL(fileURLWithPath: args[1]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for embeddingFloor in [1.0, 0.5] {
            let adapter = OfflineDiarizationAdapter(
                manifest: manifest, modelsDirectory: URL(fileURLWithPath: args[2]),
                configuration: .init(minimumEmbeddingDurationSeconds: embeddingFloor))
            let variants = try await adapter.shortTurnVariants(
                fileURL: URL(fileURLWithPath: args[0]),
                outputFloors: embeddingFloor == 1 ? [1, 0.75, 0.5, 0.25, 0] : [0.5])
            for variant in variants {
                try encoder.encode(variant).write(to: output.appendingPathComponent(variant.id + ".json"))
            }
        }
    }
}
