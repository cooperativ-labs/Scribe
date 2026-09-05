import Foundation

/// One worker-extracted, already-normalized embedding for a confirmed excerpt.
public struct ExtractedSpeakerEmbedding: Sendable, Equatable {
    public let vector: [Float]
    public let format: SpeakerEmbeddingFormat
    public let usableSpeechDuration: TimeInterval
    public let clipURL: URL?

    public init(
        vector: [Float],
        format: SpeakerEmbeddingFormat,
        usableSpeechDuration: TimeInterval,
        clipURL: URL? = nil
    ) {
        self.vector = vector
        self.format = format
        self.usableSpeechDuration = usableSpeechDuration
        self.clipURL = clipURL
    }
}

public struct SpeakerEmbeddingExtractionRequest: Sendable, Equatable {
    public let excerptID: String
    public let audioFileURL: URL
    public let ranges: [SpeakerTimeRange]
    /// A caller-owned temporary destination when the confirmed clip should be
    /// retained. The enrollment pipeline removes it after the store copies it.
    public let clipOutputURL: URL?

    public init(excerptID: String, audioFileURL: URL, ranges: [SpeakerTimeRange], clipOutputURL: URL? = nil) {
        self.excerptID = excerptID
        self.audioFileURL = audioFileURL
        self.ranges = ranges
        self.clipOutputURL = clipOutputURL
    }
}

/// Host-facing extraction seam. Production uses the transcription worker's
/// pinned WeSpeaker stack; tests substitute a deterministic double.
public protocol SpeakerEmbeddingExtracting: Sendable {
    func extract(
        _ request: SpeakerEmbeddingExtractionRequest
    ) async throws -> [ExtractedSpeakerEmbedding]
}
