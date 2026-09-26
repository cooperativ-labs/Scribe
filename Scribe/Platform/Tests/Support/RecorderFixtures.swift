import Foundation
import Platform

/// A recorder ready to start without consulting system permissions or user settings.
public func readySnapshot(
    recordingsFolderURL: URL = URL(fileURLWithPath: "/tmp/scribe", isDirectory: true)
) -> RecorderSnapshot {
    RecorderSnapshot(permissions: .allGranted, recordingsFolderURL: recordingsFolderURL)
}
