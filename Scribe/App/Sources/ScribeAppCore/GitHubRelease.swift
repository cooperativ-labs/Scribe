import Foundation

/// The small, stable portion of GitHub's release response Scribe needs to
/// download and install a signed application update.
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public struct Asset: Decodable, Sendable, Equatable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let htmlURL: URL
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    /// Only the archive produced by the release pipeline is installable.
    /// A release page or an unrelated ZIP must never enter the installer.
    public var installableArchiveURL: URL? {
        assets.first {
            $0.name == "Scribe-\(version)-macos.zip" &&
            $0.browserDownloadURL.scheme == "https" &&
            $0.browserDownloadURL.host == "github.com" &&
            $0.browserDownloadURL.path.hasPrefix("/cooperativ-labs/scribe/releases/download/")
        }?.browserDownloadURL
    }

    public var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

public enum GitHubReleaseClient {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/cooperativ-labs/scribe/releases/latest")!

    public static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Scribe update checker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubReleaseError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw GitHubReleaseError.httpStatus(response.statusCode)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

public enum GitHubReleaseError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "GitHub returned an invalid update response."
        case .httpStatus(let statusCode):
            "GitHub could not check for updates (HTTP \(statusCode))."
        }
    }
}

/// Compares the numeric, dot-separated versions produced by the release
/// script. Unrecognised tags are never treated as upgrades, avoiding a prompt
/// for a draft-style tag such as `nightly`.
public enum ScribeReleaseVersion {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = components(of: candidate),
              let currentComponents = components(of: current)
        else {
            return false
        }

        let count = max(candidateComponents.count, currentComponents.count)
        for index in 0..<count {
            let candidatePart = candidateComponents.indices.contains(index) ? candidateComponents[index] : 0
            let currentPart = currentComponents.indices.contains(index) ? currentComponents[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    private static func components(of version: String) -> [Int]? {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = normalized.hasPrefix("v") ? String(normalized.dropFirst()) : normalized
        let pieces = withoutPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        let values = pieces.compactMap { Int($0) }
        return values.count == pieces.count ? values : nil
    }
}
