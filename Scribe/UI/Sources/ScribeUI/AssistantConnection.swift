import Foundation

/// The public address ChatGPT and Claude use to reach Scribe's connector.
///
/// Both services connect from their own cloud, never from this Mac, so the
/// address has to be an HTTPS origin: a Scribe relay, or (from the CLI) a
/// tunnel or reverse proxy that forwards to the local bridge. A person may paste the bare host,
/// the origin, or the full `/mcp` endpoint a client showed them; all three name
/// the same server.
public struct AssistantServerAddress: Equatable, Sendable {
    /// `https://host[:port]`, with no trailing slash.
    public let origin: String

    /// The Streamable HTTP endpoint the clients are given.
    public var endpoint: String { origin + "/mcp" }

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case notHTTPS
        case invalid
    }

    public static func parse(_ text: String) -> Result<AssistantServerAddress, Problem> {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .failure(.empty) }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return .failure(.invalid) }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              path.isEmpty || path == "/mcp"
        else { return .failure(.invalid) }
        let port = components.port.map { ":\($0)" } ?? ""
        return .success(AssistantServerAddress(origin: "https://\(host)\(port)"))
    }

    public static func problemDescription(_ problem: Problem) -> String {
        switch problem {
        case .empty: "Enter an HTTPS address."
        case .notHTTPS: "ChatGPT and Claude only connect to HTTPS addresses."
        case .invalid: "Use an address like https://scribe.example.com, with no other path."
        }
    }
}

/// Registration names shared by the local plugin installers.
public enum AssistantConnectorCommands {
    public static let marketplaceName = "scribe-local"
    public static let pluginID = "scribe@scribe-local"
}

/// The web assistants Scribe can be added to through the relay, and what each
/// needs from a person. Desktop assistants use `AssistantHarness` instead.
public enum AssistantClient: String, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case claude

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        }
    }

    /// What the "Add to…" button says.
    public var addTitle: String {
        switch self {
        case .chatGPT: "Add to ChatGPT web"
        case .claude: "Add to Claude.ai"
        }
    }

    /// Where the "Add to…" button sends the person after copying the address.
    public var setupPage: URL {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/plugins")!
        case .claude: URL(string: "https://claude.ai/customize/connectors")!
        }
    }

    /// The step-by-step instructions shown beside the button.
    public var steps: [String] {
        let start = "In Scribe Relay above, press Connect This Mac and keep this Mac awake."
        let approve = "On Scribe’s consent page, enter a link code from Get Link Code above. Each code works once."
        switch self {
        case .chatGPT:
            return [
                start,
                "In ChatGPT, turn on Developer mode in Settings → Security and login.",
                "On the Plugins page, press +, paste the connector URL, name it Scribe, choose OAuth, and create it.",
                approve,
                "In a new chat, press + → More → Scribe, then ask for your latest transcript.",
            ]
        case .claude:
            return [
                start,
                "In Claude, open Customize → Connectors, press +, then Add custom connector.",
                "Paste the connector URL, name it Scribe, press Add, then Connect.",
                approve,
                "In a chat, press + → Connectors and turn on Scribe. It works in Claude Desktop and mobile too.",
            ]
        }
    }
}
