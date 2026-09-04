import Foundation

/// Independent speaker-library module.
///
/// Other modules identify people by `SpeakerPersonRef.profileID` values issued
/// here. Voice embeddings and enrollment clips stay in this module's local
/// store and are not part of the identity contract.
public enum SpeakersModule {
    /// Directory name under Application Support/Scribe for the speaker library.
    public static let applicationSupportSubdirectory = "Speakers"

    /// `~/Library/Application Support/Scribe/Speakers`.
    ///
    /// Vectors and enrollment clips live here, never under the transcript
    /// export directory.
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw SpeakerProfileStoreError.applicationSupportUnavailable
        }
        return root
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent(applicationSupportSubdirectory, isDirectory: true)
    }
}
