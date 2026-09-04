import Foundation

/// Host-side copy of the worker's Parakeet adapter transcript.
///
/// Keys match `ParakeetAdapter.Transcript` so recorded worker-output JSON can be
/// decoded without taking a FluidAudio dependency in this module.
public struct WorkerASRTranscript: Codable, Sendable, Equatable {
    public let text: String
    public let tokens: [WorkerTimedToken]
    /// Unmerged per-chunk token streams. Absent on the current worker, which
    /// already concatenates chunks; tests and a future unmerged stage use this.
    public let chunks: [WorkerASRChunk]?
    public let sourceDurationSeconds: TimeInterval
    public let processingTimeSeconds: TimeInterval
    public let usedChunkedProcessing: Bool
    public let timestampUnit: String

    public init(
        text: String,
        tokens: [WorkerTimedToken],
        chunks: [WorkerASRChunk]? = nil,
        sourceDurationSeconds: TimeInterval,
        processingTimeSeconds: TimeInterval = 0,
        usedChunkedProcessing: Bool = false,
        timestampUnit: String = "seconds"
    ) {
        self.text = text
        self.tokens = tokens
        self.chunks = chunks
        self.sourceDurationSeconds = sourceDurationSeconds
        self.processingTimeSeconds = processingTimeSeconds
        self.usedChunkedProcessing = usedChunkedProcessing
        self.timestampUnit = timestampUnit
    }
}

public struct WorkerTimedToken: Codable, Sendable, Equatable {
    public let text: String
    public let tokenID: Int
    /// Working-file seconds. Absolute when `timesAreAbsolute` is true on the parent chunk.
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let confidence: Float

    public init(
        text: String,
        tokenID: Int,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval,
        confidence: Float = 1
    ) {
        self.text = text
        self.tokenID = tokenID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

public struct WorkerASRChunk: Codable, Sendable, Equatable {
    public let chunkIndex: Int
    /// Start of this chunk's actual-audio window on the working file.
    public let chunkStartSeconds: TimeInterval
    /// Pinned FluidAudio ChunkProcessor emits absolute times (`true`). Relative
    /// times are restored by adding `chunkStartSeconds`.
    public let timesAreAbsolute: Bool
    public let tokens: [WorkerTimedToken]

    public init(
        chunkIndex: Int,
        chunkStartSeconds: TimeInterval,
        timesAreAbsolute: Bool = true,
        tokens: [WorkerTimedToken]
    ) {
        self.chunkIndex = chunkIndex
        self.chunkStartSeconds = chunkStartSeconds
        self.timesAreAbsolute = timesAreAbsolute
        self.tokens = tokens
    }
}

public enum WorkerASRTranscriptCodec {
    public static func decode(_ data: Data) throws -> WorkerASRTranscript {
        try JSONDecoder().decode(WorkerASRTranscript.self, from: data)
    }

    public static func encode(_ transcript: WorkerASRTranscript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transcript)
    }
}
