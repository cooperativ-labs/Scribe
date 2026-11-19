import Foundation
import ScribeAppCore

public enum SourceEnergyCheckpoint {
    private struct InvalidTimeline: LocalizedError {
        var errorDescription: String? { "Audio decoding failed: Invalid source energy timeline" }
    }

    /// Commit before the prepare stage so later stages and retries share one timeline.
    public static func write(_ timeline: SourceEnergyTimeline, in runDirectory: URL) throws {
        guard timeline.isValid else { throw InvalidTimeline() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try AtomicReplaceFileWriter().write(
            encoder.encode(timeline),
            to: runDirectory.appendingPathComponent(TranscriptRunArtifact.sourceEnergy)
        )
    }
}
