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
    @Published public var rememberedRecordingMode: RecordingMode {
        didSet { defaults.set(rememberedRecordingMode.rawValue, forKey: Key.recordingMode) }
    }
    @Published public var startShortcut: GlobalShortcut {
        didSet { storeShortcut(startShortcut, forKey: Key.startShortcut) }
    }
    @Published public var stopShortcut: GlobalShortcut {
        didSet { storeShortcut(stopShortcut, forKey: Key.stopShortcut) }
    }
    @Published public var pasteTimestampShortcut: GlobalShortcut {
        didSet { storeShortcut(pasteTimestampShortcut, forKey: Key.pasteTimestampShortcut) }
    }
    @Published public var transcribeWhenFinalRecordingIsReady: Bool {
        didSet { defaults.set(transcribeWhenFinalRecordingIsReady, forKey: Key.transcribeWhenFinalRecordingIsReady) }
    }
    /// Retains the recorder-owned session directory after its final mix has
    /// been copied into the transcript store. Off by default so successful
    /// transcription handoffs do not keep the raw component tracks forever.
    @Published public var keepRecordingFilesForDebugging: Bool {
        didSet { defaults.set(keepRecordingFilesForDebugging, forKey: Key.keepRecordingFilesForDebugging) }
    }
    /// The diarization constraint used for new imports and recorder handoffs.
    /// Automatic remains the default because attendance is not evidence that
    /// every invited person spoke or was captured.
    @Published public var microphoneSpeakerPrior: Bool {
        didSet { defaults.set(microphoneSpeakerPrior, forKey: "scribe.settings.microphoneSpeakerPrior") }
    }
    @Published public var transcriptionSpeakerCount: RecorderSpeakerCountPreference {
        didSet { defaults.set(transcriptionSpeakerCount.persistedValue, forKey: Key.transcriptionSpeakerCount) }
    }
    @Published public private(set) var launchAtLogin: Bool
    @Published public private(set) var launchAtLoginError: String?

    // MARK: Meeting detection

    /// The master switch for noticing calls. On by default.
    @Published public var meetingDetectionEnabled: Bool {
        didSet { defaults.set(meetingDetectionEnabled, forKey: Key.meetingDetectionEnabled) }
    }
    /// Finishes a recording started from the meeting chip when its detected
    /// call ends. Opt-in because an automatic finalization should never be a
    /// surprise, even though detection has its own reconnect grace period.
    @Published public var stopRecordingWhenMeetingEnds: Bool {
        didSet { defaults.set(stopRecordingWhenMeetingEnds, forKey: Key.stopRecordingWhenMeetingEnds) }
    }
    /// Catalog applications the person has unchecked. Stored as the exceptions
    /// so every application, including one added to the catalog by a later
    /// update, is watched until someone says otherwise.
    @Published public private(set) var disabledMeetingApplicationIDs: Set<String> {
        didSet { defaults.set(disabledMeetingApplicationIDs.sorted(), forKey: Key.disabledMeetingApplicationIDs) }
    }
    /// Browser hosts that count as a meeting, as bare lower-case domains.
    @Published public private(set) var meetingDomains: [String] {
        didSet { defaults.set(meetingDomains, forKey: Key.meetingDomains) }
    }

    // MARK: Calendar

    /// Names recordings and transcripts after the Apple Calendar meeting in
    /// progress when they start. Off by default: it needs calendar access, and
    /// that is a question to ask only once the person has chosen the feature.
    @Published public var useCalendarMeetingNames: Bool {
        didSet { defaults.set(useCalendarMeetingNames, forKey: Key.useCalendarMeetingNames) }
    }

    // MARK: Agent folders

    /// Folders a person has connected for handing transcripts to a coding
    /// agent, most recently connected first. Held as security-scoped bookmarks
    /// for the same reason the recordings folder is: a chosen folder has to
    /// keep working across launches, and in a sandboxed build a path alone
    /// would not.
    @Published public private(set) var agentFolderURLs: [URL]
    /// Why the last connect attempt did not take, or nil.
    @Published public private(set) var agentFolderError: String?

    public init(
        defaults: UserDefaults = .standard,
        defaultRecordingsFolderURL: URL = ScribeSettings.defaultRecordingsFolderURL,
        fileManager: FileManager = .default,
        modelManifestURL: URL? = Bundle.main.url(forResource: "model_manifest", withExtension: "json"),
        loginItemManager: LoginItemManaging = SystemLoginItemManager()
    ) {
        self.defaults = defaults
        self.defaultRecordingsFolderURL = defaultRecordingsFolderURL
        self.fileManager = fileManager
        self.loginItemManager = loginItemManager
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
        rememberedRecordingMode = defaults.string(forKey: Key.recordingMode).flatMap(RecordingMode.init(rawValue:)) ?? .systemAudioAndMicrophone
        startShortcut = Self.loadShortcut(from: defaults, key: Key.startShortcut) ?? .defaultStart
        stopShortcut = Self.loadShortcut(from: defaults, key: Key.stopShortcut) ?? .defaultStop
        pasteTimestampShortcut = Self.loadShortcut(from: defaults, key: Key.pasteTimestampShortcut) ?? .defaultPasteTimestamp
        transcribeWhenFinalRecordingIsReady = defaults.object(forKey: Key.transcribeWhenFinalRecordingIsReady) as? Bool ?? false
        keepRecordingFilesForDebugging = defaults.object(forKey: Key.keepRecordingFilesForDebugging) as? Bool ?? false
        microphoneSpeakerPrior = defaults.bool(forKey: "scribe.settings.microphoneSpeakerPrior")
        transcriptionSpeakerCount = RecorderSpeakerCountPreference(
            persistedValue: defaults.object(forKey: Key.transcriptionSpeakerCount)
        )
        launchAtLogin = loginItemManager.status == .enabled
        launchAtLoginError = nil
        meetingDetectionEnabled = defaults.object(forKey: Key.meetingDetectionEnabled) as? Bool ?? true
        stopRecordingWhenMeetingEnds = defaults.object(forKey: Key.stopRecordingWhenMeetingEnds) as? Bool ?? false
        disabledMeetingApplicationIDs = Set(defaults.stringArray(forKey: Key.disabledMeetingApplicationIDs) ?? [])
        meetingDomains = defaults.stringArray(forKey: Key.meetingDomains) ?? MeetingDomain.defaults
        useCalendarMeetingNames = defaults.object(forKey: Key.useCalendarMeetingNames) as? Bool ?? false
        // A folder that has been moved or deleted is dropped from the list
        // rather than resolved to something else: the send sheet offers what is
        // still there, and connecting it again is one button away.
        agentFolderURLs = Self.resolveBookmarks(from: defaults, key: Key.agentFolderBookmarks)
        agentFolderError = nil

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

    /// Updates macOS Login Items and reflects the result in the settings UI.
    /// The system service is authoritative because approval can also change in
    /// System Settings while Scribe is not running.
    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil

        do {
            if enabled {
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
            refreshLaunchAtLoginStatus()
            if enabled, !launchAtLogin {
                launchAtLoginError = launchAtLoginStatusMessage
            }
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
        }
    }

    /// Re-reads the system state after returning from Login Items settings.
    public func refreshLaunchAtLoginStatus() {
        launchAtLogin = loginItemManager.status == .enabled
    }

    public var launchAtLoginStatusMessage: String {
        switch loginItemManager.status {
        case .requiresApproval:
            "Approve Scribe in System Settings > General > Login Items."
        case .notFound:
            "Scribe must be installed as an app before it can launch at login."
        case .notRegistered, .enabled:
            "Scribe could not be registered to launch at login."
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

    // MARK: Meeting detection

    public func isMeetingDetectionEnabled(for application: MeetingApplication) -> Bool {
        !disabledMeetingApplicationIDs.contains(application.id)
    }

    public func setMeetingDetection(_ enabled: Bool, for application: MeetingApplication) {
        if enabled {
            disabledMeetingApplicationIDs.remove(application.id)
        } else {
            disabledMeetingApplicationIDs.insert(application.id)
        }
    }

    /// Adds a domain from whatever was typed. Returns the stored form, or `nil`
    /// when the text held no usable host. Duplicates are ignored.
    @discardableResult
    public func addMeetingDomain(_ input: String) -> String? {
        guard let domain = MeetingDomain.normalize(input) else { return nil }
        if !meetingDomains.contains(domain) { meetingDomains.append(domain) }
        return domain
    }

    public func removeMeetingDomain(_ domain: String) {
        meetingDomains.removeAll { $0 == domain }
    }

    /// Restores the built-in list, for a person who deleted `meet.google.com`
    /// and wants it back without retyping.
    public func resetMeetingDomains() {
        meetingDomains = MeetingDomain.defaults
    }

    // MARK: Agent folders

    /// Remembers a folder an agent may be started in. An already-connected
    /// folder moves to the front rather than appearing twice, so the list stays
    /// in the order the person last reached for.
    @discardableResult
    public func connectAgentFolder(_ url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        do {
            let bookmark = try standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = defaults.array(forKey: Key.agentFolderBookmarks) as? [Data] ?? []
            var urls = agentFolderURLs
            if let existing = urls.firstIndex(of: standardizedURL) {
                urls.remove(at: existing)
                if bookmarks.indices.contains(existing) { bookmarks.remove(at: existing) }
            }
            urls.insert(standardizedURL, at: 0)
            bookmarks.insert(bookmark, at: 0)
            defaults.set(bookmarks, forKey: Key.agentFolderBookmarks)
            agentFolderURLs = urls
            agentFolderError = nil
            return standardizedURL
        } catch {
            agentFolderError = ScribeSettingsError.cannotCreateBookmark(error.localizedDescription).localizedDescription
            return nil
        }
    }

    /// Forgets a connected folder. The folder itself is left alone.
    public func disconnectAgentFolder(_ url: URL) {
        guard let index = agentFolderURLs.firstIndex(of: url.standardizedFileURL) else { return }
        var bookmarks = defaults.array(forKey: Key.agentFolderBookmarks) as? [Data] ?? []
        if bookmarks.indices.contains(index) { bookmarks.remove(at: index) }
        defaults.set(bookmarks, forKey: Key.agentFolderBookmarks)
        agentFolderURLs.remove(at: index)
        agentFolderError = nil
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
        static let recordingMode = "scribe.settings.rememberedRecordingMode"
        static let startShortcut = "scribe.settings.startShortcut"
        static let stopShortcut = "scribe.settings.stopShortcut"
        static let pasteTimestampShortcut = "scribe.settings.copyTimestampShortcut"
        static let transcribeWhenFinalRecordingIsReady = "scribe.settings.transcribeWhenFinalRecordingIsReady"
        static let keepRecordingFilesForDebugging = "scribe.settings.keepRecordingFilesForDebugging"
        static let transcriptionSpeakerCount = "scribe.settings.transcriptionSpeakerCount"
        static let meetingDetectionEnabled = "scribe.settings.meetingDetectionEnabled"
        static let stopRecordingWhenMeetingEnds = "scribe.settings.stopRecordingWhenMeetingEnds"
        static let disabledMeetingApplicationIDs = "scribe.settings.disabledMeetingApplicationIDs"
        static let meetingDomains = "scribe.settings.meetingDomains"
        static let useCalendarMeetingNames = "scribe.settings.useCalendarMeetingNames"
        static let agentFolderBookmarks = "scribe.settings.agentFolderBookmarks"
    }

    private let defaults: UserDefaults
    private let defaultRecordingsFolderURL: URL
    private let fileManager: FileManager
    private let loginItemManager: LoginItemManaging

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

    /// Resolves a stored list of folder bookmarks, keeping order and dropping
    /// the ones that no longer resolve. Refreshed bookmarks are written back so
    /// a folder that merely moved keeps working.
    private static func resolveBookmarks(from defaults: UserDefaults, key: String) -> [URL] {
        guard let bookmarks = defaults.array(forKey: key) as? [Data] else { return [] }
        var resolved: [URL] = []
        var kept: [Data] = []
        for bookmark in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL, !resolved.contains(url) else { continue }
            resolved.append(url)
            if isStale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                kept.append(refreshed)
            } else {
                kept.append(bookmark)
            }
        }
        if kept.count != bookmarks.count { defaults.set(kept, forKey: key) }
        return resolved
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

/// A settings-layer representation kept independent of the transcription
/// module so recording preferences never make capture depend on the worker.
public enum RecorderSpeakerCountPreference: Hashable, Sendable {
    case automatic
    case known(Int)

    init(persistedValue: Any?) {
        if let count = persistedValue as? Int, count > 0 {
            self = .known(count)
        } else {
            self = .automatic
        }
    }

    var persistedValue: Any {
        switch self {
        case .automatic: "automatic"
        case .known(let count): count
        }
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
