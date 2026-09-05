import Foundation
import Security

public struct ApplicationUpdateError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Downloads into a private sibling directory so installation uses same-volume
/// renames. The running bundle is untouched until the app has exited.
public actor ApplicationUpdater {
    public struct PreparedUpdate: Sendable {
        let directory: URL
        let application: URL
        let destination: URL
        let requirement: String
    }

    public init() {}

    public func prepare(release: GitHubRelease, application: URL) async throws -> PreparedUpdate {
        let fm = FileManager.default
        let destination = application.standardizedFileURL
        guard destination.pathExtension == "app",
              destination.resolvingSymlinksInPath() == destination,
              !destination.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: destination.path),
              fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw ApplicationUpdateError("Move Scribe to a writable Applications folder before updating.")
        }
        let requirement = try Self.signingRequirement(for: destination)
        guard let archiveURL = release.installableArchiveURL else {
            throw ApplicationUpdateError("This release has no supported Scribe update archive. Try checking again later.")
        }
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".scribe-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var request = URLRequest(url: archiveURL)
            request.timeoutInterval = 300
            let (download, response) = try await URLSession.shared.download(for: request)
            defer { try? fm.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https" else {
                throw ApplicationUpdateError("The update download failed. Please try again.")
            }
            try Task.checkCancellation()
            let archive = directory.appendingPathComponent("update.zip")
            try fm.moveItem(at: download, to: archive)
            let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
            try Self.extractArchive(archive, to: extracted)
            let candidate = extracted.appendingPathComponent("Scribe.app", isDirectory: true)
            try Self.validateBundle(candidate, current: destination, version: release.version)
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, candidate.path])
            try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path])
            try Task.checkCancellation()
            try fm.removeItem(at: archive)
            return PreparedUpdate(directory: directory, application: candidate, destination: destination, requirement: requirement)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    public nonisolated func discard(_ update: PreparedUpdate) {
        try? FileManager.default.removeItem(at: update.directory)
    }

    static var installerResource: URL? {
        Bundle.module.url(forResource: "install-update", withExtension: "sh")
    }

    /// Start before requesting normal AppKit termination. The helper waits for
    /// the process (including recording finalization) and never kills it.
    public func launchInstaller(_ update: PreparedUpdate, processID: Int32) throws {
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", update.requirement, update.application.path])
        guard let resource = Self.installerResource else {
            throw ApplicationUpdateError("The update installer is missing. Please try again.")
        }
        let script = update.directory.appendingPathComponent("install.sh")
        try FileManager.default.copyItem(at: resource, to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(processID), update.directory.path,
                             update.application.path, update.destination.path, update.requirement]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func extractArchive(_ archive: URL, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // bsdtar reads the release ZIP and rejects traversal and writes through
        // archive-created symlinks before the untrusted bundle is verified.
        try run("/usr/bin/tar", ["-x", "-f", archive.path, "-C", directory.path])
    }

    static func validateBundle(_ candidate: URL, current: URL, version: String) throws {
        guard candidate.resolvingSymlinksInPath() == candidate.standardizedFileURL,
              let bundle = Bundle(url: candidate), let installed = Bundle(url: current),
              bundle.bundleIdentifier == installed.bundleIdentifier,
              bundle.bundleIdentifier == "com.scribe.app",
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let candidateVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let currentVersion = installed.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              candidateVersion == version,
              ScribeReleaseVersion.isNewer(candidateVersion, than: currentVersion) else {
            throw ApplicationUpdateError("The downloaded application does not match this Scribe update.")
        }
    }

    private static func signingRequirement(for application: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var information: CFDictionary?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoTeamIdentifier as String] is String,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else {
            throw ApplicationUpdateError("In-app updates require a signed release of Scribe.")
        }
        // The installed release's identity pins both bundle ID and signing team.
        return "(\(text)) and anchor apple generic"
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ApplicationUpdateError("The update could not be unpacked or verified by macOS. Please try again.")
        }
    }
}
