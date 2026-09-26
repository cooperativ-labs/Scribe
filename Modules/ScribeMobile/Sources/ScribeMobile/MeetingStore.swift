import Foundation

/// UUID directories and fixed checkpoint names form the only local file boundary.
/// No audio URL is eligible for export/sync. The whole tree is excluded from backup.
public actor MeetingStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try Self.privateDirectory(root)
    }
    public static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appending(path: "ScribeMobile")
    }
    public func directory(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    public func sourceURL(_ meeting: Meeting) throws -> URL {
        guard Self.safeFilename(meeting.sourceFilename) else { throw MobileError.message("Invalid recording filename.") }
        return directory(meeting.id).appending(path: meeting.sourceFilename)
    }
    public func create(title: String, sourceFilename: String, state: Meeting.State = .ready) throws -> Meeting {
        guard Self.safeFilename(sourceFilename) else { throw MobileError.message("Invalid recording filename.") }
        let meeting = Meeting(title: title, sourceFilename: sourceFilename, state: state)
        try Self.privateDirectory(directory(meeting.id))
        try save(meeting)
        return meeting
    }
    public func save(_ meeting: Meeting) throws {
        guard meeting.schemaVersion == 1, Self.safeFilename(meeting.sourceFilename) else {
            throw MobileError.message("Unsupported recording metadata.")
        }
        try write(meeting, id: meeting.id, name: "meeting.json")
    }
    public func load(_ id: UUID) throws -> Meeting {
        let meeting: Meeting = try read(id: id, name: "meeting.json")
        guard meeting.id == id, meeting.schemaVersion == 1, Self.safeFilename(meeting.sourceFilename) else {
            throw MobileError.message("Unsupported recording metadata.")
        }
        return meeting
    }
    public func list(recoverInterrupted: Bool = false) throws -> [Meeting] {
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try folders.compactMap { folder -> Meeting? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            var meeting = try load(id)
            if recoverInterrupted && (meeting.state.isProcessing || meeting.state == .recording || meeting.state == .importing) {
                meeting.notice = meeting.state == .recording
                    ? "Recording was interrupted. Review the recovered audio before transcribing."
                    : "Processing was interrupted. Resume to continue from the last saved stage."
                meeting.state = meeting.state == .importing ? .failed : .paused
                if meeting.sourceFilename.hasPrefix("source."), !FileManager.default.fileExists(atPath: try sourceURL(meeting).path) {
                    meeting.notice = "File import was interrupted. Delete this entry and import the recording again."
                    meeting.state = .failed
                }
                try save(meeting)
            }
            return meeting
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }
    public func write<T: Encodable>(_ value: T, id: UUID, name: String) throws {
        guard Self.safeFilename(name) else { throw MobileError.message("Invalid checkpoint filename.") }
        try JSONEncoder().encode(value).write(to: directory(id).appending(path: name), options: .atomic)
    }
    public func read<T: Decodable>(id: UUID, name: String) throws -> T {
        guard Self.safeFilename(name) else { throw MobileError.message("Invalid checkpoint filename.") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: directory(id).appending(path: name)))
    }
    public func exists(id: UUID, name: String) -> Bool {
        Self.safeFilename(name) && FileManager.default.fileExists(atPath: directory(id).appending(path: name).path)
    }
    static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }
    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    public static func protectAudio(_ url: URL) throws {
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
        #endif
    }
}
