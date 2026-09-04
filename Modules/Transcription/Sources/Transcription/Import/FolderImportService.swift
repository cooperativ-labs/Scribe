import Foundation
import ScribeAppCore

/// Content-based media inspection, injectable so unit tests need no ffprobe.
public protocol MediaProbing: Sendable {
    func probe(_ sourceURL: URL) throws -> MediaProbeResult
}

extension MediaProber: MediaProbing {}

public struct FolderImportOptions: Sendable {
    /// The scan is non-recursive by default; this is the "Include subfolders" switch.
    public var includeSubfolders: Bool
    /// The module's own output, excluded so an import never re-imports a transcript store.
    public var transcriptStoreDirectory: URL?
    /// Processing inputs folded into each file's fingerprint.
    public var configuration: ImportConfiguration
    /// Hashing every file is what makes repeat-import detection content-based.
    /// A caller that wants a fast listing first can turn it off and fingerprint
    /// the files a person actually selected.
    public var fingerprintsDuringScan: Bool

    public init(
        configuration: ImportConfiguration,
        includeSubfolders: Bool = false,
        transcriptStoreDirectory: URL? = nil,
        fingerprintsDuringScan: Bool = true
    ) {
        self.configuration = configuration
        self.includeSubfolders = includeSubfolders
        self.transcriptStoreDirectory = transcriptStoreDirectory
        self.fingerprintsDuringScan = fingerprintsDuringScan
    }
}

/// A structured per-file error. One bad file never stops the rest of a folder.
public struct ImportFileFailure: Equatable, Sendable, Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: MediaProbeError) {
        switch error {
        case .corrupt(let details): self.init(code: "import.file.corrupt", message: "This file is not valid media data: \(details)")
        case .encrypted(let details): self.init(code: "import.file.encrypted", message: "This file is encrypted and cannot be transcribed: \(details)")
        case .unsupported(let details): self.init(code: "import.file.unsupported", message: "This file's format is not supported: \(details)")
        case .executableUnavailable(let url): self.init(code: "import.file.proberUnavailable", message: "The bundled media prober is unavailable at \(url.path).")
        case .executionFailed(let details): self.init(code: "import.file.probeFailed", message: "This file could not be inspected: \(details)")
        }
    }
}

/// Why an entry never reached the import list at all.
public enum ImportExclusionReason: Equatable, Sendable {
    case hidden
    case temporary
    case transcriptStore
    /// A recorder session's `capture/` segment directory: module input, not user media.
    case recorderCaptureDirectory
    /// A recorder session's own `metadata.json`: module input, not user media.
    case recorderSessionMetadata
    /// A link that resolves outside the folder the user chose. Never followed.
    case symlinkOutsideSelectedTree(resolvedPath: String)
    /// A subfolder, when "Include subfolders" is off.
    case subfolder
    case notARegularFile
    case unreadableDirectory(String)

    public var message: String {
        switch self {
        case .hidden: "Hidden files are not imported."
        case .temporary: "Temporary and partially written files are not imported."
        case .transcriptStore: "This is the transcript store, which holds this module's own output."
        case .recorderCaptureDirectory: "This is a recording's raw capture directory, not importable media."
        case .recorderSessionMetadata: "This is a recording's metadata file, not importable media."
        case .symlinkOutsideSelectedTree(let path): "This link points outside the selected folder (\(path)) and was not followed."
        case .subfolder: "Subfolders are not scanned. Turn on \u{201C}Include subfolders\u{201D} to include this folder."
        case .notARegularFile: "This is not a regular file."
        case .unreadableDirectory(let reason): "This folder could not be read: \(reason)"
        }
    }
}

public struct ExcludedEntry: Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public let reason: ImportExclusionReason
}

/// One row of the import list.
public struct ImportedFile: Equatable, Sendable, Identifiable {
    /// The relative path, not the file name: identical names in different
    /// folders are different rows and must never collapse into one.
    public var id: String { relativePath }

    public let url: URL
    public let relativePath: String
    /// `nil` when probing failed; `failure` then says why.
    public let probe: MediaProbeResult?
    public let failure: ImportFileFailure?
    /// `nil` when the file failed, or when fingerprinting was deferred.
    public let fingerprint: ImportFingerprint?
    public let isPreselected: Bool
    /// Always present when `isPreselected` is false, so the list can show a reason.
    public let deselectionReason: String?
    public let recorderSessionDirectoryURL: URL?
    public let recorderTrackRole: RecorderSessionTrackRole?

    public var isImportable: Bool { failure == nil }
    /// True when the container holds several audio streams and one must be chosen.
    public var requiresStreamSelection: Bool { (probe?.audioStreamCount ?? 0) > 1 }
}

public struct FolderImportResult: Equatable, Sendable {
    public let rootURL: URL
    /// Naturally sorted by relative path.
    public let files: [ImportedFile]
    public let excluded: [ExcludedEntry]
    public let recorderSessions: [RecorderSession]

    public var preselectedFiles: [ImportedFile] { files.filter(\.isPreselected) }
    public var failedFiles: [ImportedFile] { files.filter { $0.failure != nil } }
}

public enum FolderImportError: Error, Equatable, Sendable {
    case rootUnreadable(String)
    case rootIsNotADirectory
}

/// Enumerates a chosen folder, probes what it finds, recognizes recorder output,
/// and reports a reason for everything it will not transcribe.
///
/// The service is deliberately pure with respect to the store: it reads the
/// folder and reports. Creating snapshots is `SourceSnapshotService`'s job, and
/// running anything is the coordinator's.
public struct FolderImportService: Sendable {
    /// Suffixes that mark a file still being written by something else.
    /// A trailing `~` is the conventional editor backup; the rest are
    /// in-progress download and export names.
    static let temporarySuffixes = [".tmp", ".temp", ".part", ".partial", ".crdownload", ".download", "~"]
    /// Office's in-progress lock files. Dot-prefixed temporaries are already hidden.
    static let temporaryPrefixes = ["~$"]

    private let prober: MediaProbing
    private let recognizer: RecorderSessionRecognizer
    // FileManager's documented contract permits concurrent use of an instance's
    // file operations; the reference is held unsafely rather than making the
    // whole service a class just to satisfy the checker.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        prober: MediaProbing,
        recognizer: RecorderSessionRecognizer = RecorderSessionRecognizer(),
        fileManager: FileManager = .default
    ) {
        self.prober = prober
        self.recognizer = recognizer
        self.fileManager = fileManager
    }

    public func scan(_ rootURL: URL, options: FolderImportOptions) throws -> FolderImportResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            throw FolderImportError.rootUnreadable("\(rootURL.path) does not exist.")
        }
        guard isDirectory.boolValue else { throw FolderImportError.rootIsNotADirectory }

        // Symlink containment is measured against the *resolved* root, so that
        // selecting a folder that is itself a link still works while links
        // escaping that tree do not.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let storeDirectory = options.transcriptStoreDirectory?.resolvingSymlinksInPath().standardizedFileURL

        var candidates: [ScannedFile] = []
        var excluded: [ExcludedEntry] = []
        var sessions: [URL: RecorderSession] = [:]

        func scanDirectory(_ directory: URL, resolvedDirectory: URL, relativePrefix: String) {
            let session = recognizer.recognizeSession(at: directory)
            if let session { sessions[resolvedDirectory] = session }

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
                    // Hidden entries are enumerated so they can be reported as
                    // skipped rather than vanishing without explanation.
                    options: []
                )
            } catch {
                excluded.append(ExcludedEntry(
                    url: directory,
                    relativePath: relativePrefix.isEmpty ? "." : String(relativePrefix.dropLast()),
                    reason: .unreadableDirectory(error.localizedDescription)
                ))
                return
            }

            for entry in entries {
                let name = entry.lastPathComponent
                let relativePath = relativePrefix + name

                if isHidden(entry) {
                    excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .hidden))
                    continue
                }

                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
                if values?.isSymbolicLink == true, !isContained(resolved, in: resolvedRoot) {
                    excluded.append(ExcludedEntry(
                        url: entry,
                        relativePath: relativePath,
                        reason: .symlinkOutsideSelectedTree(resolvedPath: resolved.path)
                    ))
                    continue
                }

                var resolvedIsDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: resolved.path, isDirectory: &resolvedIsDirectory)

                if exists, resolvedIsDirectory.boolValue {
                    if let storeDirectory, isContained(resolved, in: storeDirectory) || resolved == storeDirectory {
                        excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .transcriptStore))
                        continue
                    }
                    if name == "capture", fileManager.fileExists(atPath: directory.appendingPathComponent(RecorderSessionRecognizer.manifestFileName).path) {
                        excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .recorderCaptureDirectory))
                        continue
                    }
                    guard options.includeSubfolders else {
                        excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .subfolder))
                        continue
                    }
                    scanDirectory(entry, resolvedDirectory: resolved, relativePrefix: relativePath + "/")
                    continue
                }

                guard exists, values?.isRegularFile == true || !resolvedIsDirectory.boolValue else {
                    excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .notARegularFile))
                    continue
                }
                if isTemporary(name) {
                    excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .temporary))
                    continue
                }
                // The manifest describes the session; it is never one of its tracks.
                if session != nil, name == RecorderSessionRecognizer.manifestFileName {
                    excluded.append(ExcludedEntry(url: entry, relativePath: relativePath, reason: .recorderSessionMetadata))
                    continue
                }
                candidates.append(ScannedFile(url: entry, relativePath: relativePath, sessionDirectory: resolvedDirectory))
            }
        }

        if let storeDirectory, resolvedRoot == storeDirectory {
            throw FolderImportError.rootUnreadable("The transcript store cannot be imported as a source folder.")
        }
        scanDirectory(rootURL, resolvedDirectory: resolvedRoot, relativePrefix: "")

        let files = candidates
            .sorted { NaturalPathOrder.compare($0.relativePath, $1.relativePath) == .orderedAscending }
            .map { inspect($0, session: sessions[$0.sessionDirectory], options: options) }

        return FolderImportResult(
            rootURL: rootURL,
            files: files,
            excluded: excluded.sorted { NaturalPathOrder.compare($0.relativePath, $1.relativePath) == .orderedAscending },
            recorderSessions: sessions.values.sorted { $0.directoryURL.path < $1.directoryURL.path }
        )
    }

    /// Probes and fingerprints one file, then decides whether it is preselected.
    ///
    /// Every failure is captured on the row it belongs to; none of them
    /// terminate the scan, which is what lets a folder of mostly-good files
    /// import while a corrupt one sits beside them with its reason shown.
    private func inspect(_ candidate: ScannedFile, session: RecorderSession?, options: FolderImportOptions) -> ImportedFile {
        let role = session?.role(ofFileNamed: candidate.url.lastPathComponent)

        var probe: MediaProbeResult?
        var failure: ImportFileFailure?
        do { probe = try prober.probe(candidate.url) }
        catch let error as MediaProbeError { failure = ImportFileFailure(error) }
        catch { failure = ImportFileFailure(code: "import.file.probeFailed", message: "This file could not be inspected: \(error.localizedDescription)") }

        var fingerprint: ImportFingerprint?
        if failure == nil, options.fingerprintsDuringScan {
            do { fingerprint = try ImportFingerprint(fileAt: candidate.url, configuration: options.configuration) }
            catch { failure = ImportFileFailure(code: "import.file.unreadable", message: "This file could not be read: \(error.localizedDescription)") }
        }

        let (isPreselected, reason) = selection(failure: failure, session: session, role: role)
        return ImportedFile(
            url: candidate.url,
            relativePath: candidate.relativePath,
            probe: failure == nil ? probe : nil,
            failure: failure,
            fingerprint: fingerprint,
            isPreselected: isPreselected,
            deselectionReason: reason,
            recorderSessionDirectoryURL: session?.directoryURL,
            recorderTrackRole: role
        )
    }

    private func selection(
        failure: ImportFileFailure?,
        session: RecorderSession?,
        role: RecorderSessionTrackRole?
    ) -> (Bool, String?) {
        if let failure { return (false, failure.message) }
        // A file with no declared role in a session folder — say, a voice memo
        // dropped beside a recording — is ordinary media.
        guard let session, let role else { return (true, nil) }

        switch role {
        case .finalMix:
            if let rejection = session.rejection { return (false, rejection.message) }
            return (true, nil)
        case .system, .microphone:
            // The whole point: these are ingredients of the final mix. Leaving
            // them selectable but unselected stops the same meeting being
            // transcribed three times without hiding the tracks.
            let label = role == .system ? "system audio" : "microphone"
            if let rejection = session.rejection {
                return (false, "This is the \(label) track of a recording. \(rejection.message)")
            }
            return (false, "This is the \(label) track of a recording; its final mix is selected instead. Select it explicitly to transcribe it on its own.")
        }
    }

    private func isHidden(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") { return true }
        return (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

    private func isTemporary(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        if Self.temporarySuffixes.contains(where: lowercased.hasSuffix) { return true }
        return Self.temporaryPrefixes.contains(where: name.hasPrefix)
    }

    /// Path containment on standardized paths, comparing whole components so
    /// `/tmp/rootsibling` is never treated as inside `/tmp/root`.
    private func isContained(_ url: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard components.count > rootComponents.count else { return components == rootComponents }
        return Array(components.prefix(rootComponents.count)) == rootComponents
    }
}

private struct ScannedFile {
    let url: URL
    let relativePath: String
    /// The resolved directory the file was found in, used to look up its session.
    let sessionDirectory: URL
}

/// Natural ordering of relative paths.
///
/// Comparison runs component by component so files stay grouped with their
/// folder, and digit runs compare numerically so `track2` precedes `track10`.
/// The locale is pinned to `nil` so an import list does not reorder itself when
/// the user's region changes, and an exact-bytes tiebreak keeps the order total.
enum NaturalPathOrder {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: "/", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "/", omittingEmptySubsequences: false)
        for (a, b) in zip(left, right) {
            let natural = String(a).compare(String(b), options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale: nil)
            if natural != .orderedSame { return natural }
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}
