import Foundation

/// The version-1 launch manifest `latch create --manifest-file -` accepts.
///
/// This is Latch's contract, not Scribe's, so the field names are Latch's
/// spelling and the document is written exactly as documented rather than
/// through a translation layer that could drift. It travels over standard
/// input, which is the point of the interface: nothing in it reaches another
/// process's argument list or a file on disk.
///
/// `latch` validates the same three things this type validates before writing:
/// a program in `argv`, an absolute `cwd`, and non-zero terminal dimensions.
/// Checking them here means a bad request is reported in Scribe's own words
/// instead of as a CLI failure a person cannot act on.
public struct LatchLaunchManifest: Codable, Equatable, Sendable {
    /// The only schema version Latch reads today.
    public static let currentFormatVersion = 1
    /// Latch normalizes the terminal type; this is the value it pins.
    public static let defaultTerm = "xterm-256color"

    public struct TerminalSize: Codable, Equatable, Sendable {
        public let cols: Int
        public let rows: Int

        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    public struct Launch: Codable, Equatable, Sendable {
        /// Program and arguments. Latch never persists these.
        public let argv: [String]
        /// The child's working directory. Must be absolute.
        public let cwd: String
        /// Set on the child only.
        public let env: [String: String]
        public let inheritEnv: Bool
        public let size: TerminalSize
        public let term: String

        enum CodingKeys: String, CodingKey {
            case argv, cwd, env, size, term
            case inheritEnv = "inherit_env"
        }

        public init(
            argv: [String],
            cwd: String,
            env: [String: String] = [:],
            inheritEnv: Bool = true,
            size: TerminalSize = TerminalSize(cols: 120, rows: 40),
            term: String = LatchLaunchManifest.defaultTerm
        ) {
            self.argv = argv
            self.cwd = cwd
            self.env = env
            self.inheritEnv = inheritEnv
            self.size = size
            self.term = term
        }
    }

    /// Where a session came from. Latch sanitizes and retains all of it, so
    /// none of these fields may carry a secret.
    public struct Source: Codable, Equatable, Sendable {
        public let kind: String
        public let externalRunID: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case externalRunID = "external_run_id"
        }

        public init(kind: String, externalRunID: String? = nil) {
            self.kind = kind
            self.externalRunID = externalRunID
        }
    }

    public struct Display: Codable, Equatable, Sendable {
        public let name: String?
        public let title: String?
        public let commandLabel: String?
        public let source: Source

        enum CodingKeys: String, CodingKey {
            case name, title, source
            case commandLabel = "command_label"
        }

        public init(name: String?, title: String?, commandLabel: String?, source: Source) {
            self.name = name
            self.title = title
            self.commandLabel = commandLabel
            self.source = source
        }
    }

    public let formatVersion: Int
    public let launch: Launch
    public let display: Display

    enum CodingKeys: String, CodingKey {
        case launch, display
        case formatVersion = "format_version"
    }

    public init(formatVersion: Int = LatchLaunchManifest.currentFormatVersion, launch: Launch, display: Display) {
        self.formatVersion = formatVersion
        self.launch = launch
        self.display = display
    }

    /// The bytes to write on `latch create`'s standard input.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard let program = launch.argv.first, !program.isEmpty else {
            throw LatchLaunchManifestError.missingProgram
        }
        guard launch.cwd.hasPrefix("/") else {
            throw LatchLaunchManifestError.relativeWorkingDirectory(launch.cwd)
        }
        guard launch.size.cols > 0, launch.size.rows > 0 else {
            throw LatchLaunchManifestError.emptyTerminalSize
        }
    }
}

public enum LatchLaunchManifestError: LocalizedError, Equatable {
    case missingProgram
    case relativeWorkingDirectory(String)
    case emptyTerminalSize

    public var errorDescription: String? {
        switch self {
        case .missingProgram:
            "The agent's command is empty, so there is nothing for Latch to run."
        case .relativeWorkingDirectory(let path):
            "The agent's folder must be an absolute path; \u{201C}\(path)\u{201D} is not."
        case .emptyTerminalSize:
            "A Latch session needs a terminal size with both dimensions above zero."
        }
    }
}

/// What `latch create --json` reports back.
///
/// Only the fields Scribe acts on are decoded: Latch is free to add more, and
/// an added field must not turn a created session into a reported failure.
public struct LatchCreateReport: Decodable, Equatable, Sendable {
    public struct Session: Decodable, Equatable, Sendable {
        public let id: String
        public let name: String?
        public let state: String?

        public init(id: String, name: String?, state: String?) {
            self.id = id
            self.name = name
            self.state = state
        }
    }

    public let protocolVersion: Int?
    public let session: Session
    /// Present when Scribe passed `--request-id`: true when an earlier
    /// attempt of the same send had already started this session.
    public let reused: Bool?

    public init(protocolVersion: Int?, session: Session, reused: Bool? = nil) {
        self.protocolVersion = protocolVersion
        self.session = session
        self.reused = reused
    }

    public static func decode(_ data: Data) throws -> LatchCreateReport {
        try JSONDecoder().decode(LatchCreateReport.self, from: data)
    }
}

/// What `latch create --request-id … --json` writes instead of a report when
/// the request started nothing: a stable code and a sentence.
public struct LatchCreateErrorReport: Decodable, Equatable, Sendable {
    public struct ErrorBody: Decodable, Equatable, Sendable {
        public let code: String
        public let message: String
        public let sessionId: String?
    }

    public let error: ErrorBody

    public static func decode(_ data: Data) throws -> LatchCreateErrorReport {
        try JSONDecoder().decode(LatchCreateErrorReport.self, from: data)
    }
}

/// The part of `latch capabilities --json` Scribe reads.
public struct LatchCapabilitiesReport: Decodable, Equatable, Sendable {
    /// `latch create` takes `--request-id` and starts at most one session
    /// per ID.
    public static let createRequestIDExtension = "create-request-id"

    public struct Capabilities: Decodable, Equatable, Sendable {
        public let extensions: [String]

        public init(extensions: [String]) { self.extensions = extensions }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        }

        enum CodingKeys: String, CodingKey { case extensions }
    }

    public let capabilities: Capabilities

    public static func decode(_ data: Data) throws -> LatchCapabilitiesReport {
        try JSONDecoder().decode(LatchCapabilitiesReport.self, from: data)
    }
}
