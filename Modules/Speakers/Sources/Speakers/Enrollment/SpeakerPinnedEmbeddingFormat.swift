import Foundation

/// Compatibility metadata that must match the worker's exported WeSpeaker
/// vectors before enrollment or matching. These values are pinned to
/// `OfflineDiarizationAdapter` / `model_manifest.json`.
public enum SpeakerPinnedEmbeddingFormat {
    public static let modelID = "wespeaker-embedding-coreml"
    public static let modelRevision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
    public static let preprocessingVersion = "fluidaudio-offline-fbank-16khz-mono-v0.12.4"
    public static let normalizationVersion = "l2-unit-v1"
    /// The worker re-applies L2 normalization after centroid averaging and does
    /// not export an additional x-vector transform.
    public static let transformVersion = "identity-v1"

    public static var model: SpeakerEmbeddingModelIdentity {
        SpeakerEmbeddingModelIdentity(modelID: modelID, revision: modelRevision)
    }

    public static var current: SpeakerEmbeddingFormat {
        SpeakerEmbeddingFormat(
            model: model,
            preprocessingVersion: preprocessingVersion,
            normalizationVersion: normalizationVersion,
            transformVersion: transformVersion
        )
    }
}
