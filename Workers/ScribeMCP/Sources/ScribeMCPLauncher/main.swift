import AppKit
import CoreServices
import Foundation

// scribe-mcp-launcher: what plugin manifests run. It finds Scribe.app through
// LaunchServices on every start, never through a stored path, so moving or
// updating the app cannot break a plugin, then replaces itself with the app's
// helper. stdin, stdout, stderr, arguments and environment pass through as-is.
// SCRIBE_MCP_HELPER names a helper to run instead, for development and tests.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("scribe-mcp-launcher: \(message)\n".utf8))
    exit(69) // EX_UNAVAILABLE
}

func installedHelper() -> String? {
    // LaunchServices can retain an old registration after an app is moved,
    // even after the moved copy is opened. Prefer a running copy so a relaunch
    // from the new folder takes effect immediately.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.scribe.app")
        .compactMap(\.bundleURL)
    let registered = LSCopyApplicationURLsForBundleIdentifier("com.scribe.app" as CFString, nil)?.takeRetainedValue() as? [URL] ?? []
    let apps = running + registered
    return apps.lazy
        .map { $0.appending(path: "Contents/Helpers/scribe-mcp").path(percentEncoded: false) }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

let override = ProcessInfo.processInfo.environment["SCRIBE_MCP_HELPER"].flatMap { $0.isEmpty ? nil : $0 }
guard let helper = override ?? installedHelper() else {
    fail("Scribe is not installed. Install Scribe.app from https://scribe.ovld.ai and try again.")
}
let arguments = [helper] + CommandLine.arguments.dropFirst()
let argv = arguments.map { strdup($0) } + [nil]
execv(helper, argv)
fail("could not start \(helper): \(String(cString: strerror(errno)))")
