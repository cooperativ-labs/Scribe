import Foundation

// MARK: - Applications

/// One application whose calls Scribe can notice.
///
/// The catalog is a fixed list rather than "whatever is running": a person
/// chooses in Settings which of these Scribe should watch, and the choice has
/// to be stable across launches and mean the same thing whether or not the
/// application happens to be open right now.
public struct MeetingApplication: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        /// A dedicated calling application: using the microphone is the call.
        case nativeApp
        /// A Chromium browser: the call is a tab on one of the chosen domains.
        case chromiumBrowser
    }

    /// Stable key persisted in Settings, independent of bundle identifiers so a
    /// vendor renaming its bundle (as Teams did) does not reset the choice.
    public let id: String
    public let name: String
    /// Every main-application bundle identifier the vendor has shipped under.
    /// Helper processes are matched by `matches(processBundleIdentifier:)`.
    public let bundleIdentifiers: [String]
    public let kind: Kind

    public init(id: String, name: String, bundleIdentifiers: [String], kind: Kind) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.kind = kind
    }

    public var isBrowser: Bool { kind == .chromiumBrowser }

    /// Whether an audio-client bundle identifier belongs to this application.
    ///
    /// Electron and Chromium apps open the microphone from a helper process
    /// whose identifier is the parent's plus `.helper…`, and at least one vendor
    /// (Arc) changes the case of the parent portion in its helpers, so the
    /// comparison is case-insensitive. A sibling product such as
    /// `com.google.Chrome.beta` is deliberately not treated as Chrome's helper.
    public func matches(processBundleIdentifier candidate: String) -> Bool {
        let candidate = candidate.lowercased()
        return bundleIdentifiers.contains { identifier in
            let identifier = identifier.lowercased()
            return candidate == identifier || candidate.hasPrefix(identifier + ".helper")
        }
    }

    /// Every application Scribe knows how to watch, in the order Settings lists them.
    public static let catalog: [MeetingApplication] = [
        MeetingApplication(id: "zoom", name: "Zoom", bundleIdentifiers: ["us.zoom.xos"], kind: .nativeApp),
        MeetingApplication(id: "chrome", name: "Google Chrome", bundleIdentifiers: ["com.google.Chrome"], kind: .chromiumBrowser),
        MeetingApplication(id: "arc", name: "Arc", bundleIdentifiers: ["company.thebrowser.Browser"], kind: .chromiumBrowser),
        MeetingApplication(id: "edge", name: "Microsoft Edge", bundleIdentifiers: ["com.microsoft.edgemac"], kind: .chromiumBrowser),
        MeetingApplication(id: "brave", name: "Brave", bundleIdentifiers: ["com.brave.Browser"], kind: .chromiumBrowser),
        MeetingApplication(id: "vivaldi", name: "Vivaldi", bundleIdentifiers: ["com.vivaldi.Vivaldi"], kind: .chromiumBrowser),
        MeetingApplication(id: "opera", name: "Opera", bundleIdentifiers: ["com.operasoftware.Opera"], kind: .chromiumBrowser),
        MeetingApplication(id: "chromium", name: "Chromium", bundleIdentifiers: ["org.chromium.Chromium"], kind: .chromiumBrowser),
        MeetingApplication(id: "teams", name: "Microsoft Teams", bundleIdentifiers: ["com.microsoft.teams2", "com.microsoft.teams"], kind: .nativeApp),
        MeetingApplication(id: "slack", name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], kind: .nativeApp),
        MeetingApplication(id: "facetime", name: "FaceTime", bundleIdentifiers: ["com.apple.FaceTime"], kind: .nativeApp),
        MeetingApplication(id: "whatsapp", name: "WhatsApp", bundleIdentifiers: ["net.whatsapp.WhatsApp"], kind: .nativeApp),
        MeetingApplication(id: "signal", name: "Signal", bundleIdentifiers: ["org.whispersystems.signal-desktop"], kind: .nativeApp),
        MeetingApplication(id: "discord", name: "Discord", bundleIdentifiers: ["com.hnc.Discord"], kind: .nativeApp),
    ]

    /// The catalog entries Settings should offer on this Mac.
    ///
    /// The named calling applications are always offered, installed or not, so
    /// the list reads the same on every machine. Browsers are offered only when
    /// installed: nobody wants to be asked about six browsers they do not have.
    public static func offered(isInstalled: (MeetingApplication) -> Bool) -> [MeetingApplication] {
        catalog.filter { !$0.isBrowser || isInstalled($0) }
    }

    public static func application(matchingProcessBundleIdentifier candidate: String) -> MeetingApplication? {
        catalog.first { $0.matches(processBundleIdentifier: candidate) }
    }
}

// MARK: - Domains

/// Host-name rules for the browser side of detection.
///
/// A domain is stored as a bare lower-case host. It matches that host and any
/// subdomain, so `zoom.us` covers `us05web.zoom.us` without the person having
/// to know Zoom's regional hosts.
public enum MeetingDomain {
    public static let defaults = ["meet.google.com"]

    /// Turns what a person typed into a stored domain, or `nil` when nothing
    /// usable remains. Accepts a full URL, a host with a path, or a bare host.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let schemeRange = text.range(of: "://") {
            text = String(text[schemeRange.upperBound...])
        }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.contains("."), !text.contains(" ") else { return nil }
        return text
    }

    public static func host(_ host: String, matches domain: String) -> Bool {
        let host = host.lowercased()
        let domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    /// The first configured domain a URL belongs to, if any.
    public static func matchingDomain(for url: URL, among domains: [String]) -> String? {
        guard let urlHost = url.host?.lowercased() else { return nil }
        return domains.first { host(urlHost, matches: $0) }
    }
}

// MARK: - Result

/// A call Scribe believes is in progress.
public struct DetectedMeeting: Equatable, Sendable {
    public let application: MeetingApplication
    /// The main application's bundle identifier that matched, which is what the
    /// application picker and the capture scope use.
    public let bundleIdentifier: String
    /// The process that has the microphone open. For browsers and Electron apps
    /// this is a helper, so it is informational rather than a capture target.
    public let processIdentifier: pid_t
    /// The configured domain a browser tab matched. `nil` for native
    /// applications, and for a browser whose tabs could not be read.
    public let domain: String?
    public let detectedAt: Date

    public init(application: MeetingApplication, bundleIdentifier: String, processIdentifier: pid_t, domain: String?, detectedAt: Date) {
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.domain = domain
        self.detectedAt = detectedAt
    }

    /// "Zoom", or "meet.google.com in Arc".
    public var displayName: String {
        guard let domain else { return application.name }
        return "\(domain) in \(application.name)"
    }
}
