import CryptoKit
import Foundation

public struct ModelManifest: Codable, Sendable {
    public struct Asset: Codable, Sendable {
        public let id: String
        public let relativePath: String
        public let upstream: Upstream
        public let checksum: Checksum
        public let license: String
        public let requiredFiles: [RequiredFile]
    }

    public struct Upstream: Codable, Sendable {
        public let repository: String
        public let revision: String
    }

    public struct Checksum: Codable, Sendable {
        public let algorithm: String
        public let value: String
        public let scope: String
    }

    public struct RequiredFile: Codable, Sendable {
        public let relativePath: String
        public let sha256: String?
        public let bytes: Int?
    }

    public let schemaVersion: Int
    public let profileID: String
    public let fluidAudio: Upstream
    public let telemetry: Telemetry
    public let totalDeclaredOnDiskBytes: Int
    public let assets: [Asset]

    public struct Telemetry: Codable, Sendable {
        public let enabled: Bool
        public let runtimeDownloadsAllowed: Bool
    }

    public static func load(from url: URL) throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url))
    }

    /// Validates exactly the staged files. It never asks FluidAudio, Core ML, or
    /// a model host to fill a gap; callers get one structured setup error with
    /// all missing or mismatched paths.
    public func validate(modelsDirectory: URL) -> AssetValidationReport {
        var failures: [AssetValidationFailure] = []
        for asset in assets {
            let assetURL = modelsDirectory.appending(path: asset.relativePath, directoryHint: .isDirectory)
            for file in asset.requiredFiles {
                let fileURL = assetURL.appending(path: file.relativePath, directoryHint: .notDirectory)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    failures.append(.init(assetID: asset.id, path: fileURL.path, reason: "missing"))
                    continue
                }
                do {
                    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                    if let expectedBytes = file.bytes, data.count != expectedBytes {
                        failures.append(.init(assetID: asset.id, path: fileURL.path, reason: "size mismatch (expected \(expectedBytes), found \(data.count))"))
                    }
                    if let expectedSHA256 = file.sha256 {
                        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        if actual != expectedSHA256.lowercased() {
                            failures.append(.init(assetID: asset.id, path: fileURL.path, reason: "SHA-256 mismatch"))
                        }
                    }
                } catch {
                    failures.append(.init(assetID: asset.id, path: fileURL.path, reason: "unreadable: \(error.localizedDescription)"))
                }
            }
        }
        return AssetValidationReport(modelsDirectory: modelsDirectory.path, failures: failures)
    }
}

public struct AssetValidationReport: Codable, Sendable {
    public let modelsDirectory: String
    public let failures: [AssetValidationFailure]
    public var isValid: Bool { failures.isEmpty }
}

public struct AssetValidationFailure: Codable, Sendable {
    public let assetID: String
    public let path: String
    public let reason: String
}
