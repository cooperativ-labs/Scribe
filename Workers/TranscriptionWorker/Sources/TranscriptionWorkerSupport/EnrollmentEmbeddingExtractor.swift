import Foundation

/// Extracts a single-speaker embedding from confirmed enrollment ranges by
/// clipping those ranges and running the pinned offline diarizer with an
/// exact speaker count of one. This uses the same WeSpeaker conversion,
/// preprocessing, and L2 normalization as full-file diarization export.
public struct EnrollmentEmbeddingExtractor: Sendable {
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        case noEmbedding
        case multipleSpeakers(Int)

        public var errorDescription: String? {
            switch self {
            case .noEmbedding:
                "The worker produced no embedding for the enrollment clip."
            case let .multipleSpeakers(count):
                "The enrollment clip produced \(count) speakers; confirmed examples must contain one person."
            }
        }
    }

    public let adapter: OfflineDiarizationAdapter

    public init(manifest: ModelManifest, modelsDirectory: URL) {
        self.adapter = OfflineDiarizationAdapter(
            manifest: manifest,
            modelsDirectory: modelsDirectory,
            configuration: .init(knownSpeakerCount: 1)
        )
    }

    public init(adapter: OfflineDiarizationAdapter) {
        self.adapter = adapter
    }

    public func extract(
        from fileURL: URL,
        ranges: [AudioTimeRange],
        retainingClipAt retainedClipURL: URL? = nil
    ) async throws -> OfflineDiarizationAdapter.SpeakerEmbedding {
        let temporaryDirectory = retainedClipURL == nil ? FileManager.default.temporaryDirectory.appending(
            path: "scribe-enrollment-\(UUID().uuidString)", directoryHint: .isDirectory
        ) : nil
        let clipURL = retainedClipURL ?? temporaryDirectory!.appending(path: "excerpt.wav")
        try FileManager.default.createDirectory(at: clipURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) } }
        _ = try EnrollmentAudioClipper.writeClip(from: fileURL, ranges: ranges, to: clipURL)
        let result = try await adapter.diarize(fileURL: clipURL)
        guard result.embeddings.count <= 1 else {
            throw Error.multipleSpeakers(result.embeddings.count)
        }
        guard let embedding = result.embeddings.first else {
            throw Error.noEmbedding
        }
        return embedding
    }
}
