import CryptoKit
import Foundation
import ScribeAppCore

/// Streaming content hashing shared by the importer and the snapshot service.
///
/// The digest is a lowercase SHA-256 hex string, matching the recorder's
/// `RecorderTrackManifest.checksum` so a manifest checksum can be verified with
/// the same routine that produced it.
public enum FileContentHash {
    /// Reads the file in 1 MiB chunks so a multi-gigabyte recording never has to
    /// be resident in memory to be identified.
    public static func sha256(ofFileAt url: URL) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += Int64(chunk.count)
        }
        return (hasher.finalize().scribeHexString, byteCount)
    }

    public static func sha256(of data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().scribeHexString
    }
}

extension Digest {
    var scribeHexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// The processing inputs that decide whether two runs over the same audio are
/// comparable.
///
/// Everything here changes the transcript that comes out, so a change to any
/// field makes a rerun a genuinely new run rather than a repeat import. Fields
/// that only decide where exports are *written* are deliberately absent: writing
/// TXT somewhere else does not invalidate a canonical transcript.
public struct ImportConfiguration: Codable, Equatable, Sendable {
    public var modelProfileID: String
    public var languageMode: TranscriptionLanguageMode
    public var expectedLanguage: String?
    public var speakerCount: TranscriptionSpeakerCount
    public var speakerMatching: TranscriptionSpeakerMatching
    public var speakerLibraryRevision: String?
    public var channelSelection: AudioChannelSelection
    /// The ffprobe stream index chosen for a multitrack container, when one was chosen.
    public var audioStreamIndex: Int?

    public init(
        modelProfileID: String,
        languageMode: TranscriptionLanguageMode = .automatic,
        expectedLanguage: String? = nil,
        speakerCount: TranscriptionSpeakerCount = .automatic,
        speakerMatching: TranscriptionSpeakerMatching = .enabled,
        speakerLibraryRevision: String? = nil,
        channelSelection: AudioChannelSelection = .downmix,
        audioStreamIndex: Int? = nil
    ) {
        self.modelProfileID = modelProfileID
        self.languageMode = languageMode
        self.expectedLanguage = expectedLanguage
        self.speakerCount = speakerCount
        self.speakerMatching = speakerMatching
        self.speakerLibraryRevision = speakerLibraryRevision
        self.channelSelection = channelSelection
        self.audioStreamIndex = audioStreamIndex
    }

    /// A canonical, key-sorted rendering hashed into `fingerprint`.
    ///
    /// It is written by hand rather than derived from `JSONEncoder` so that
    /// adding an unrelated field, or a change in encoder behavior, cannot
    /// silently invalidate every checkpoint recorded by an earlier build.
    var canonicalDescription: String {
        let fields: [String: String] = [
            "audioStreamIndex": audioStreamIndex.map(String.init) ?? "automatic",
            "channelSelection": channelSelection.rawValue,
            "expectedLanguage": expectedLanguage ?? "",
            "languageMode": languageMode.rawValue,
            "modelProfileID": modelProfileID,
            "speakerCount": {
                switch speakerCount {
                case .automatic: "automatic"
                case .known(let count): String(count)
                }
            }(),
            "speakerLibraryRevision": speakerLibraryRevision ?? "",
            "speakerMatching": speakerMatching.rawValue,
        ]
        let body = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: "\n")
        return "scribe.import.configuration.v1\n" + body
    }

    public var fingerprint: String {
        FileContentHash.sha256(of: Data(canonicalDescription.utf8))
    }
}

/// Identifies a source file by what is in it and how it will be processed.
///
/// `contentHash` alone answers "is this the same audio?" — which is why two
/// files with identical names in different folders never collide, and why the
/// same audio copied to a second folder is correctly recognized as one meeting.
/// `configurationHash` answers "would the run produce the same transcript?".
public struct ImportFingerprint: Codable, Equatable, Hashable, Sendable {
    /// Lowercase SHA-256 hex of the file bytes.
    public let contentHash: String
    public let byteCount: Int64
    public let configurationHash: String

    public init(contentHash: String, byteCount: Int64, configurationHash: String) {
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.configurationHash = configurationHash
    }

    public init(fileAt url: URL, configuration: ImportConfiguration) throws {
        let hashed = try FileContentHash.sha256(ofFileAt: url)
        self.init(contentHash: hashed.digest, byteCount: hashed.byteCount, configurationHash: configuration.fingerprint)
    }

    /// The transcript-store identity of the *audio*, used for `meeting--<source-id>`.
    ///
    /// It excludes the configuration on purpose: section 8 keeps reruns as new
    /// run directories inside one meeting directory rather than as new meetings.
    /// 128 bits of the digest is ample to keep distinct recordings apart while
    /// keeping the directory name readable.
    public var sourceID: String { String(contentHash.prefix(32)) }

    /// The full identity of one processing run over this content.
    public var value: String { "\(contentHash).\(configurationHash)" }
}
