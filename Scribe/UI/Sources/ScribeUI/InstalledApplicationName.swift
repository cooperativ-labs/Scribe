import AppKit
import Foundation

/// Names an application that is remembered but not running, so the pickers can
/// say "Zoom (not running)" rather than showing a bundle identifier.
///
/// Launch Services is asked once per identifier and the answer is cached: the
/// lookup is a disk hit, and the presentation is recomputed every second while
/// a recording is running.
@MainActor
enum InstalledApplicationName {
    private static var cache: [String: String?] = [:]

    static func lookup(bundleIdentifier: String) -> String? {
        if let cached = cache[bundleIdentifier] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map { url in
            let displayName = FileManager.default.displayName(atPath: url.path)
            return displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        }
        cache[bundleIdentifier] = name
        return name
    }

    /// The row label for a remembered application that is not running.
    static func unavailableLabel(for source: UnavailableSource) -> String {
        "\(lookup(bundleIdentifier: source.id) ?? source.id) (not running)"
    }
}
