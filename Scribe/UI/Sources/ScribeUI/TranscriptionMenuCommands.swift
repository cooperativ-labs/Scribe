import Foundation

/// The transcription entries the menu offers, supplied by the host.
///
/// The menu owns no transcription state and calls no module API directly: the
/// recorder must keep working when transcription is missing, failing, or busy,
/// so this is a plain value the host fills in and the menu only renders. When
/// the host provides nothing, the section disappears entirely.
@MainActor
public struct TranscriptionMenuCommands {
    /// Progress and queue lines, listed separately from the recorder's own
    /// background processing because a queued transcription says nothing about
    /// whether the recorder is free.
    public var statusLines: [String]
    /// A structured failure worth showing, such as a missing helper.
    public var failure: String?
    public var openTranscripts: () -> Void
    public var openSpeakers: (() -> Void)?
    public var transcribeFolder: () -> Void

    public init(
        statusLines: [String] = [],
        failure: String? = nil,
        openTranscripts: @escaping () -> Void,
        openSpeakers: (() -> Void)? = nil,
        transcribeFolder: @escaping () -> Void
    ) {
        self.statusLines = statusLines
        self.failure = failure
        self.openTranscripts = openTranscripts
        self.openSpeakers = openSpeakers
        self.transcribeFolder = transcribeFolder
    }
}
