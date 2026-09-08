import Foundation

/// Independent custom-vocabulary module.
///
/// The library is one always-on personal list of terms that transcription
/// merges into every job, plus optional named packs that are unioned with it
/// rather than picked per recording. See
/// `docs/decisions/custom-transcription-vocabulary.md` for why there is no
/// per-meeting picker.
///
/// Nothing here talks to the ASR engine. The module owns the durable list, its
/// revision, and the editing surfaces (the Settings section and the
/// `scribe-vocab` command); the transcription pipeline reads a snapshot.
public enum VocabularyModule {
    /// Directory name under Application Support/Scribe for the vocabulary.
    public static let applicationSupportSubdirectory = "Vocabulary"

    /// `~/Library/Application Support/Scribe/Vocabulary`.
    ///
    /// Application Support rather than `UserDefaults`: a working glossary grows
    /// past preference-size comfort, and the speaker library already
    /// established this as the place for durable personal data.
    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw VocabularyStoreError.applicationSupportUnavailable
        }
        return root
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent(applicationSupportSubdirectory, isDirectory: true)
    }
}
