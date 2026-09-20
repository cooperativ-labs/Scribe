import AppKit

/// The system clipboard boundary used by transcript actions.
///
/// Keeping this small seam injectable lets review tests verify the exact
/// document copied without depending on the user's pasteboard.
@MainActor
public protocol TranscriptClipboardWriting {
    func write(_ text: String) -> Bool
}

@MainActor
public final class SystemTranscriptClipboard: TranscriptClipboardWriting {
    public init() {}

    public func write(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
