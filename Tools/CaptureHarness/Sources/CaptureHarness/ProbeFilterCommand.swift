import Foundation
import ScreenCaptureKit

/// `capture-harness probe-filter` — the application-filter half of the device matrix.
///
/// For each requested application family it enumerates every process the three system
/// sources know about, reports which of them a content filter can actually name, and then
/// captures the same moment of audio through two filters: the main bundle identifier only,
/// and the main identifier plus every helper. Comparing the delivered levels is the only
/// way to answer whether selecting "Chrome" captures a Google Meet tab's audio, or whether
/// the helper process has to be named as well.
enum ProbeFilterCommand {
    static func run(_ raw: [String]) async -> Int32 {
        do {
            let arguments = try Arguments(raw)
            let families = try requestedFamilies(arguments)
            let seconds = try arguments.double("seconds", default: 20)
            let enumerateOnly = arguments.flag("enumerate-only")
            let microphoneUID = arguments.string("microphone-uid")
            let directory = outputDirectory(arguments)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var results: [[String: Any]] = []
            var lines: [String] = []

            // Without the screen-recording grant there is no shareable content, and so no
            // content filter. Enumeration still has value then — NSWorkspace and the process
            // table show the helper topology — so it degrades to that instead of failing, and
            // says which column is missing. Capturing without the grant is impossible, so the
            // capturing modes still fail loudly.
            var shareable: SCShareableContent?
            var shareableError: String?
            do {
                shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                shareableError = error.localizedDescription
                guard enumerateOnly else { throw CaptureError.shareableContent(error.localizedDescription) }
            }
            if let shareableError {
                lines.append("ScreenCaptureKit visibility unavailable: \(shareableError)")
                lines.append("Every 'SCK' column below is therefore unknown, not false. Grant Screen & System Audio Recording and rerun for the filterable-identifier answer.")
            }

            for family in families {
                let processes = ApplicationCatalog.processes(in: family, shareable: shareable)
                let (main, helpers) = ApplicationCatalog.filterableIdentifiers(in: family, processes: processes)

                lines.append("")
                lines.append("== \(family.displayName) (\(family.key)) ==")
                lines.append("Hypothesis: \(family.hypothesis)")
                if processes.isEmpty {
                    lines.append("Not running. Start it and rerun; the harness never substitutes another source.")
                    results.append([
                        "family": family.key,
                        "displayName": family.displayName,
                        "hypothesis": family.hypothesis,
                        "running": false,
                        "processes": [],
                        "variants": [],
                    ])
                    continue
                }
                for process in processes {
                    let visibility = [
                        process.visibleToScreenCaptureKit ? "SCK" : (shareableError == nil ? nil : "SCK unknown"),
                        process.visibleToWorkspace ? "NSWorkspace" : nil,
                    ].compactMap { $0 }
                    let sources = visibility.isEmpty ? "process table only" : visibility.joined(separator: "+")
                    let identifier = process.bundleIdentifier.isEmpty ? "(no bundle identifier)" : process.bundleIdentifier
                    lines.append("  pid \(process.processID)  \(identifier)  \(process.name)  [\(sources)]")
                }
                lines.append("  Filterable main identifiers: \(main.isEmpty ? "none" : main.joined(separator: ", "))")
                lines.append("  Filterable helper identifiers: \(helpers.isEmpty ? "none" : helpers.joined(separator: ", "))")
                let shared = helpers.filter { family.isSharedHelper(bundleIdentifier: $0) }
                if !shared.isEmpty {
                    lines.append("  \(shared.joined(separator: ", ")) is shared with every other host application on this Mac; only the processes macOS named '\(family.helperNamePrefix ?? family.displayName)…' are listed above. A filter naming that identifier alone would also capture other applications' media.")
                }
                let invisible = shareableError == nil ? processes.filter { !$0.visibleToScreenCaptureKit } : []
                if !invisible.isEmpty {
                    lines.append("  \(invisible.count) process(es) exist that no content filter can name; if audio comes from one of these, application filtering cannot capture it.")
                }

                var variants: [[String: Any]] = []
                if !enumerateOnly {
                    let pidsBefore = Set(processes.map(\.processID))
                    for variant in filterVariants(family: family, main: main, helpers: helpers) {
                        lines.append("  Recording variant '\(variant.label)' for \(Int(seconds)) s — make \(family.displayName) produce audio now.")
                        let outcome = await ProbeRun.capture(
                            label: "\(family.key)-\(variant.label)",
                            scope: .applications(bundleIdentifiers: variant.identifiers, label: "\(family.key)/\(variant.label)"),
                            seconds: seconds,
                            microphoneDeviceID: microphoneUID,
                            directory: directory.appendingPathComponent("\(family.key)-\(variant.label)")
                        )
                        lines.append("    \(outcome.verdict)")
                        variants.append(outcome.journalObject)
                    }
                    let after = ApplicationCatalog.processes(in: family, shareable: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false))
                    let pidsAfter = Set(after.map(\.processID))
                    if pidsBefore != pidsAfter {
                        let started = pidsAfter.subtracting(pidsBefore).sorted()
                        let ended = pidsBefore.subtracting(pidsAfter).sorted()
                        lines.append("  Process set changed during the probe (started: \(started), ended: \(ended)). A filter built at start cannot include a process that appeared later — this is why the plan requires resolving the application at capture start.")
                    } else {
                        lines.append("  Process set unchanged across the probe.")
                    }
                }

                results.append([
                    "family": family.key,
                    "displayName": family.displayName,
                    "hypothesis": family.hypothesis,
                    "running": true,
                    "processes": processes.map(\.journalObject),
                    "filterableMainIdentifiers": main,
                    "filterableHelperIdentifiers": helpers,
                    "sharedHelperIdentifiers": helpers.filter { family.isSharedHelper(bundleIdentifier: $0) },
                    "unfilterableProcessCount": invisible.count,
                    "variants": variants,
                ])
            }

            let summary: [String: Any] = [
                "schemaVersion": 1,
                "tool": "capture-harness probe-filter",
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "secondsPerVariant": enumerateOnly ? 0 : seconds,
                "enumerateOnly": enumerateOnly,
                "screenCaptureKitVisibility": shareableError.map { "unavailable: \($0)" } ?? "available",
                "families": results,
                "finishedAt": Timestamp.iso8601(),
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let summaryURL = directory.appendingPathComponent("filter-probe.json")
            try data.write(to: summaryURL)

            print(lines.joined(separator: "\n"))
            print("\nSummary: \(summaryURL.path)")
            return 0
        } catch {
            fputs("capture-harness probe-filter: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    struct FilterVariant {
        let label: String
        let identifiers: [String]
    }

    /// `main-only` is what a user selecting the application in the UI would get.
    /// `main-plus-helpers` is the widest filter that still names only this application's
    /// processes. Running both is what turns a guess about helper audio into a measurement.
    static func filterVariants(family: ApplicationFamily, main: [String], helpers: [String]) -> [FilterVariant] {
        var variants: [FilterVariant] = []
        if !main.isEmpty { variants.append(FilterVariant(label: "main-only", identifiers: main)) }
        if !helpers.isEmpty {
            variants.append(FilterVariant(label: "main-plus-helpers", identifiers: main + helpers))
            if main.isEmpty { variants.append(FilterVariant(label: "helpers-only", identifiers: helpers)) }
        }
        return variants
    }

    private static func requestedFamilies(_ arguments: Arguments) throws -> [ApplicationFamily] {
        guard let raw = arguments.string("targets") else { return ApplicationFamily.all }
        let keys = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return try keys.map { key in
            guard let family = ApplicationFamily.named(key) else {
                throw ArgumentError(message: "Unknown target '\(key)'. Known targets: \(ApplicationFamily.all.map(\.key).joined(separator: ", ")).")
            }
            return family
        }
    }

    private static func outputDirectory(_ arguments: Arguments) -> URL {
        if let path = arguments.string("output") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("captures")
            .appendingPathComponent("filter-probe \(Timestamp.sessionStamp())")
    }
}
