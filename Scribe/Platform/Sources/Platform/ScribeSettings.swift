import Combine
import Foundation

/// The persistent preferences used by the menu-bar workflow.
///
/// The recordings directory is represented by a security-scoped bookmark rather
/// than a path so the same preference continues to work in a sandboxed build.
@MainActor
public final class ScribeSettings: ObservableObject {
    public nonisolated static let defaultRecordingsFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Meeting Recordings", isDirectory: true)

    public nonisolated static let defaultModelsFolderURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scribe/Models", isDirectory: true)

    @Published public private(set) var modelsFolderURL: URL
    @Published public private(set) var modelsFolderError: String?
    public let modelInstaller: TranscriptionModelInstaller

    @Published public private(set) var recordingsFolderURL: URL
    @Published public private(set) var recordingsFolderError: ScribeSettingsError?
    @Published public var rememberedApplicationBundleIdentifier: String? {
        didSet { storeOptionalString(rememberedApplicationBundleIdentifier, forKey: Key.applicationBundleIdentifier) }
    }
    @Published public var rememberedMicrophoneID: String? {
        didSet { storeOptionalString(rememberedMicrophoneID, forKey: Key.microphoneID) }
    }
    @Published public var startShortcut: GlobalShortcut {
        didSet { storeShortcut(startShortcut, forKey: Key.startShortcut) }
    }
    @Published public var stopShortcut: GlobalShortcut {
        didSet { storeShortcut(stopShortcut, forKey: Key.stopShortcut) }
    }
    @Published public var transcribeWhenFinalRecordingIsReady: Bool {
        didSet { defaults.set(transcribeWhenFinalRecordingIsReady, forKey: Key.transcribeWhenFinalRecordingIsReady) }
    }

    public init(
        defaults: UserDefaults = .standard,
        defaultRecordingsFolderURL: URL = ScribeSettings.defaultRecordingsFolderURL,
        fileManager: FileManager = .default,
        modelManifestURL: URL? = Bundle.main.url(forResource: "model_manifest", withExtension: "json")
    ) {
        self.defaults = defaults
        self.defaultRecordingsFolderURL = defaultRecordingsFolderURL
        self.fileManager = fileManager
        modelInstaller = TranscriptionModelInstaller(manifestURL: modelManifestURL)
        do {
            modelsFolderURL = try Self.resolveBookmark(from: defaults, fileManager: fileManager, key: Key.modelsFolderBookmark)
                ?? Self.defaultModelsFolderURL
        } catch {
            modelsFolderURL = Self.defaultModelsFolderURL
            modelsFolderError = "The saved models folder could not be opened. Choose it again: \(error.localizedDescription)"
        }

        rememberedApplicationBundleIdentifier = defaults.string(forKey: Key.applicationBundleIdentifier)
        rememberedMicrophoneID = defaults.string(forKey: Key.microphoneID)
        startShortcut = Self.loadShortcut(from: defaults, key: Key.startShortcut) ?? .defaultStart
        stopShortcut = Self.loadShortcut(from: defaults, key: Key.stopShortcut) ?? .defaultStop
        transcribeWhenFinalRecordingIsReady = defaults.object(forKey: Key.transcribeWhenFinalRecordingIsReady) as? Bool ?? false

        recordingsFolderURL = defaultRecordingsFolderURL
        modelInstaller.refresh(directory: modelsFolderURL)

        do {
            recordingsFolderURL = try Self.resolveBookmark(from: defaults, fileManager: fileManager)
                ?? defaultRecordingsFolderURL
        } catch {
            recordingsFolderURL = defaultRecordingsFolderURL
            recordingsFolderError = .invalidBookmark(error.localizedDescription)
            return
        }
        recordingsFolderError = nil

        // Store the default as a bookmark immediately, not only after the user
        // changes it. This makes a relaunch behave the same as a selected folder.
        if defaults.data(forKey: Key.recordingsFolderBookmark) == nil {
            do {
                try setRecordingsFolder(defaultRecordingsFolderURL)
            } catch {
                recordingsFolderError = error as? ScribeSettingsError ?? .cannotCreateBookmark(error.localizedDescription)
            }
        }
    }

    /// Persists a folder selection as a security-scoped bookmark.
    public func setRecordingsFolder(_ url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        do {
            try fileManager.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
            let bookmark = try standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Key.recordingsFolderBookmark)
            recordingsFolderURL = standardizedURL
            recordingsFolderError = nil
        } catch {
            let settingsError = ScribeSettingsError.cannotCreateBookmark(error.localizedDescription)
            recordingsFolderError = settingsError
            throw settingsError
        }
    }

    /// Selecting a new root leaves existing models in place. The installer
    /// recognizes a complete installation there or offers to download it.
    public func setModelsFolder(_ url: URL) throws {
        guard !modelInstaller.isBusy else { throw ModelInstallationError("Wait for model setup to finish or cancel the download first.") }
        let url = url.standardizedFileURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: Key.modelsFolderBookmark)
        modelsFolderURL = url
        modelsFolderError = nil
        modelInstaller.refresh(directory: url)
    }

    /// Executes a short file operation while the persisted security scope is open.
    public func withRecordingsFolderAccess<Result>(_ operation: (URL) throws -> Result) rethrows -> Result {
        let didStartAccessing = recordingsFolderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                recordingsFolderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try operation(recordingsFolderURL)
    }

    private enum Key {
        static let modelsFolderBookmark = "scribe.settings.modelsFolderBookmark"
        static let recordingsFolderBookmark = "scribe.settings.recordingsFolderBookmark"
        static let applicationBundleIdentifier = "scribe.settings.rememberedApplicationBundleIdentifier"
        static let microphoneID = "scribe.settings.rememberedMicrophoneID"
        static let startShortcut = "scribe.settings.startShortcut"
        static let stopShortcut = "scribe.settings.stopShortcut"
        static let transcribeWhenFinalRecordingIsReady = "scribe.settings.transcribeWhenFinalRecordingIsReady"
    }

    private let defaults: UserDefaults
    private let defaultRecordingsFolderURL: URL
    private let fileManager: FileManager

    private func storeOptionalString(_ value: String?, forKey key: String) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func storeShortcut(_ shortcut: GlobalShortcut, forKey key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadShortcut(from defaults: UserDefaults, key: String) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }

    private static func resolveBookmark(from defaults: UserDefaults, fileManager: FileManager, key: String = Key.recordingsFolderBookmark) throws -> URL? {
        guard let bookmark = defaults.data(forKey: key) else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        if isStale {
            let refreshedBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(refreshedBookmark, forKey: key)
        }
        return url
    }
}

public enum ScribeSettingsError: LocalizedError, Equatable {
    case invalidBookmark(String)
    case cannotCreateBookmark(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark(let reason): "The saved recordings folder could not be opened: \(reason)"
        case .cannotCreateBookmark(let reason): "The recordings folder could not be saved: \(reason)"
        }
    }
}
