import AppKit
import Darwin
import Foundation
import ScreenCaptureKit

/// A meeting application (or browser) and the helper processes that may actually
/// render its audio.
///
/// IMPLEMENTATION_PLAN.md section 1 says audio filtering is application-level and that
/// browser helper-process behaviour must be verified: selecting Chrome must be described
/// as recording Chrome's audio, not a single Meet tab. Chromium renders and mixes audio in
/// a helper process, and WebKit uses `com.apple.WebKit.GPU`. Whether those helpers appear
/// to ScreenCaptureKit as separate `SCRunningApplication`s — and whether a filter naming
/// only the main bundle identifier still receives their audio — is measured, never assumed.
struct ApplicationFamily: Sendable {
    /// Short name used on the command line and in the report.
    let key: String
    let displayName: String
    /// Bundle identifiers a user would recognise as "the application".
    let mainBundleIdentifiers: [String]
    /// Prefixes that also belong to this family, used to spot helper processes.
    let bundleIdentifierPrefixes: [String]
    /// Substring of a helper's executable path, for helpers that report no bundle
    /// identifier of their own and so never reach `SCShareableContent.applications`.
    let executablePathFragments: [String]
    /// Bundle identifiers this family shares with every other host application on the
    /// system. `com.apple.WebKit.GPU` is one process class used by Mail, Raycast and any
    /// other WebKit host, so naming it in a content filter would capture their media too.
    /// Processes carrying one of these identifiers belong to this family only when their
    /// application name starts with `helperNamePrefix`.
    let sharedHelperIdentifierPrefixes: [String]
    /// Name prefix that identifies this family's instances of a shared helper.
    let helperNamePrefix: String?
    /// What the family is expected to do, as a hypothesis the probe tests.
    let hypothesis: String

    static let all: [ApplicationFamily] = [zoom, safari, chrome, teams]

    static let zoom = ApplicationFamily(
        key: "zoom",
        displayName: "Zoom",
        mainBundleIdentifiers: ["us.zoom.xos"],
        bundleIdentifierPrefixes: ["us.zoom."],
        executablePathFragments: ["/zoom.us.app/"],
        sharedHelperIdentifierPrefixes: [],
        helperNamePrefix: nil,
        hypothesis: "Native app; meeting audio is expected from the main process, with helpers (caphost, aomhost) present but silent."
    )

    static let safari = ApplicationFamily(
        key: "safari",
        displayName: "Safari",
        mainBundleIdentifiers: ["com.apple.Safari"],
        bundleIdentifierPrefixes: ["com.apple.Safari", "com.apple.WebKit"],
        executablePathFragments: ["/Safari.app/"],
        sharedHelperIdentifierPrefixes: ["com.apple.WebKit", "com.apple.SafariPlatformSupport"],
        helperNamePrefix: "Safari",
        hypothesis: "WebKit renders media in com.apple.WebKit.GPU, a separate process outside the Safari bundle identifier."
    )

    static let chrome = ApplicationFamily(
        key: "chrome",
        displayName: "Google Chrome",
        mainBundleIdentifiers: ["com.google.Chrome"],
        bundleIdentifierPrefixes: ["com.google.Chrome"],
        executablePathFragments: ["/Google Chrome.app/"],
        sharedHelperIdentifierPrefixes: [],
        helperNamePrefix: nil,
        hypothesis: "Chromium mixes audio in a helper process whose bundle identifier is com.google.Chrome.helper (or a .renderer/.gpu variant)."
    )

    static let teams = ApplicationFamily(
        key: "teams",
        displayName: "Microsoft Teams",
        mainBundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"],
        bundleIdentifierPrefixes: ["com.microsoft.teams"],
        executablePathFragments: ["/Microsoft Teams.app/", "/Microsoft Teams (work or school).app/"],
        sharedHelperIdentifierPrefixes: [],
        helperNamePrefix: nil,
        hypothesis: "Electron-based; audio may come from the main process or from a Chromium helper as in Chrome."
    )

    static func named(_ key: String) -> ApplicationFamily? {
        all.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    func claims(bundleIdentifier: String) -> Bool {
        bundleIdentifierPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    func isSharedHelper(bundleIdentifier: String) -> Bool {
        sharedHelperIdentifierPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    /// A shared helper belongs to this family only when macOS named it after this
    /// application. `Safari Web Content` is Safari's; `Mail Web Content` is not, and a
    /// filter that captured it would be recording another application's audio.
    func claims(bundleIdentifier: String, applicationName: String) -> Bool {
        guard claims(bundleIdentifier: bundleIdentifier) else { return false }
        guard isSharedHelper(bundleIdentifier: bundleIdentifier), let helperNamePrefix else { return true }
        return applicationName.hasPrefix(helperNamePrefix)
    }

    func isMain(_ bundleIdentifier: String) -> Bool {
        mainBundleIdentifiers.contains(bundleIdentifier)
    }
}

/// One process the probe found, and where it was found.
struct ProcessRecord: Sendable {
    let bundleIdentifier: String
    let name: String
    let processID: pid_t
    let executablePath: String?
    /// True when `SCShareableContent` listed it, i.e. a content filter can name it.
    let visibleToScreenCaptureKit: Bool
    /// True when NSWorkspace lists it as a running application (has a UI presence).
    let visibleToWorkspace: Bool

    var journalObject: [String: Any] {
        var object: [String: Any] = [
            "bundleIdentifier": bundleIdentifier,
            "name": name,
            "pid": Int(processID),
            "visibleToScreenCaptureKit": visibleToScreenCaptureKit,
            "visibleToWorkspace": visibleToWorkspace,
        ]
        if let executablePath { object["executablePath"] = executablePath }
        return object
    }
}

enum ApplicationCatalog {
    /// Every process belonging to `family`, merged from ScreenCaptureKit, NSWorkspace and
    /// the process table. The three sources disagree in exactly the interesting cases:
    /// a helper that renders audio but is invisible to `SCShareableContent` cannot be named
    /// in a content filter at all.
    ///
    /// `shareable` is optional because enumeration is still informative without the
    /// screen-recording grant; a nil value means ScreenCaptureKit visibility is *unknown*,
    /// and callers must say so rather than reporting every process as invisible.
    static func processes(in family: ApplicationFamily, shareable: SCShareableContent?) -> [ProcessRecord] {
        var byPID: [pid_t: ProcessRecord] = [:]

        for application in shareable?.applications ?? []
        where family.claims(bundleIdentifier: application.bundleIdentifier, applicationName: application.applicationName) {
            byPID[application.processID] = ProcessRecord(
                bundleIdentifier: application.bundleIdentifier,
                name: application.applicationName,
                processID: application.processID,
                executablePath: nil,
                visibleToScreenCaptureKit: true,
                visibleToWorkspace: false
            )
        }

        for running in NSWorkspace.shared.runningApplications {
            let identifier = running.bundleIdentifier ?? ""
            guard family.claims(bundleIdentifier: identifier, applicationName: running.localizedName ?? "") else { continue }
            let path = running.executableURL?.path
            if var existing = byPID[running.processIdentifier] {
                existing = ProcessRecord(
                    bundleIdentifier: existing.bundleIdentifier,
                    name: existing.name,
                    processID: existing.processID,
                    executablePath: path,
                    visibleToScreenCaptureKit: existing.visibleToScreenCaptureKit,
                    visibleToWorkspace: true
                )
                byPID[running.processIdentifier] = existing
            } else {
                byPID[running.processIdentifier] = ProcessRecord(
                    bundleIdentifier: identifier,
                    name: running.localizedName ?? identifier,
                    processID: running.processIdentifier,
                    executablePath: path,
                    visibleToScreenCaptureKit: false,
                    visibleToWorkspace: true
                )
            }
        }

        for entry in ProcessTable.entries() {
            guard family.executablePathFragments.contains(where: { entry.path.contains($0) }) else { continue }
            guard byPID[entry.pid] == nil else {
                if byPID[entry.pid]?.executablePath == nil {
                    let existing = byPID[entry.pid]!
                    byPID[entry.pid] = ProcessRecord(
                        bundleIdentifier: existing.bundleIdentifier,
                        name: existing.name,
                        processID: existing.processID,
                        executablePath: entry.path,
                        visibleToScreenCaptureKit: existing.visibleToScreenCaptureKit,
                        visibleToWorkspace: existing.visibleToWorkspace
                    )
                }
                continue
            }
            byPID[entry.pid] = ProcessRecord(
                bundleIdentifier: "",
                name: (entry.path as NSString).lastPathComponent,
                processID: entry.pid,
                executablePath: entry.path,
                visibleToScreenCaptureKit: false,
                visibleToWorkspace: false
            )
        }

        return byPID.values.sorted { ($0.bundleIdentifier, $0.processID) < ($1.bundleIdentifier, $1.processID) }
    }

    /// Bundle identifiers a content filter can actually name, split into the main
    /// application and the helpers. Only ScreenCaptureKit-visible processes qualify.
    static func filterableIdentifiers(
        in family: ApplicationFamily,
        processes: [ProcessRecord]
    ) -> (main: [String], helpers: [String]) {
        let visible = processes.filter { $0.visibleToScreenCaptureKit && !$0.bundleIdentifier.isEmpty }
        let main = Set(visible.map(\.bundleIdentifier)).filter { family.isMain($0) }
        let helpers = Set(visible.map(\.bundleIdentifier)).subtracting(main)
        return (main.sorted(), helpers.sorted())
    }
}

/// Reads the BSD process table so helpers with no bundle identifier are still seen.
enum ProcessTable {
    struct Entry: Sendable {
        let pid: pid_t
        let path: String
    }

    static func entries() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&name, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let actual = size / MemoryLayout<kinfo_proc>.stride

        var result: [Entry] = []
        result.reserveCapacity(actual)
        var pathBuffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        for index in 0..<actual {
            let pid = processes[index].kp_proc.p_pid
            guard pid > 0 else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            result.append(Entry(pid: pid, path: String(decoding: pathBuffer[0..<Int(length)], as: UTF8.self)))
        }
        return result
    }
}
