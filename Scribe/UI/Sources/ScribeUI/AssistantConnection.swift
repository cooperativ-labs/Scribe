import Foundation

/// How ChatGPT and Claude, which connect from their own cloud, reach this Mac.
public enum AssistantConnectionMode: String, CaseIterable, Identifiable, Sendable {
    /// This Mac links to a shared Scribe relay and keeps an outbound connection
    /// open. Every owner uses the relay's one address; no tunnel is needed.
    case relay
    /// The person runs the HTTP bridge behind their own HTTPS tunnel or proxy.
    case selfHosted

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .relay: "Scribe Relay"
        case .selfHosted: "Your own tunnel"
        }
    }
}

/// The public address ChatGPT and Claude use to reach Scribe's connector.
///
/// Both services connect from their own cloud, never from this Mac, so the
/// address has to be an HTTPS origin: a Scribe relay, or a tunnel or reverse
/// proxy that forwards to the local bridge. A person may paste the bare host,
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

/// The assistants Scribe can be added to, and what each needs from a person.
public enum AssistantClient: String, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case claude
    case claudeCode

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .claudeCode: "Claude Code"
        }
    }

    /// Where the "Add to…" button sends the person after copying the address.
    public var setupPage: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/plugins")
        case .claude: URL(string: "https://claude.ai/customize/connectors")
        case .claudeCode: nil
        }
    }

    /// The step-by-step instructions shown beside the button.
    public func steps(mode: AssistantConnectionMode = .relay) -> [String] {
        let approve = mode == .relay
            ? "On Scribe’s consent page, enter a link code from Get Link Code above. Each code works once."
            : "Approve the connection on Scribe’s consent page with your owner key."
        let start = mode == .relay
            ? "In Scribe Relay above, press Connect This Mac and keep this Mac awake."
            : "Start Scribe’s connector server and your HTTPS tunnel."
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
        case .claudeCode:
            return [
                "Press Add to Claude Code. Scribe installs its plugin with the claude command.",
                "Restart Claude Code and run /mcp to check that scribe is connected.",
                "Ask for your latest transcript, or use /scribe:scribe-transcripts.",
            ]
        }
    }
}

/// Builds the commands a person runs to serve and install the connector.
public enum AssistantConnectorCommands {
    /// Claude's documented OAuth callback for custom connectors.
    public static let claudeCallback = "https://claude.ai/api/mcp/auth_callback"
    /// ChatGPT's stable callback, which it uses because Scribe's OAuth server
    /// names its issuer in every authorization response (RFC 9207).
    public static let chatGPTCallback = "https://chatgpt.com/connector_platform_oauth_redirect"
    public static let marketplaceName = "scribe-local"
    public static let pluginID = "scribe@scribe-local"

    /// The callbacks a self-hosted server allows: Claude's and ChatGPT's stable
    /// callbacks, plus a connection-specific one a person copied out of ChatGPT.
    public static func redirectURIs(chatGPTCallback custom: String) -> [String] {
        var uris = [claudeCallback, chatGPTCallback]
        let callback = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: callback), url.scheme == "https", url.host != nil, !uris.contains(callback) {
            uris.append(callback)
        }
        return uris
    }

    /// Creates the owner key once, then serves the connector on loopback for
    /// the tunnel to forward to.
    public static func serverCommand(cli: URL, address: AssistantServerAddress, chatGPTCallback: String) -> String {
        let uris = redirectURIs(chatGPTCallback: chatGPTCallback).map { "\"\($0)\"" }.joined(separator: ",")
        return """
        SCRIBE_CLI=\(shellQuoted(cli.path))
        [ -f "$HOME/Library/Application Support/Scribe/MCP/owner-key" ] || node "$SCRIBE_CLI" init
        SCRIBE_PUBLIC_URL=\(shellQuoted(address.origin)) SCRIBE_OAUTH_REDIRECT_URIS=\(shellQuoted("[\(uris)]")) node "$SCRIBE_CLI" http
        """
    }

    /// Links this Mac to the relay on first run, then serves its library over
    /// an outbound connection until stopped. Nothing listens on this Mac.
    public static func relayConnectCommand(cli: URL, relay: AssistantServerAddress) -> String {
        """
        SCRIBE_CLI=\(shellQuoted(cli.path))
        node "$SCRIBE_CLI" connect \(shellQuoted(relay.origin))
        """
    }

    /// What "Add to Claude Code" runs, for a person who prefers a terminal.
    public static func claudeCodeInstallCommand(marketplace: URL) -> String {
        """
        claude plugin marketplace add \(shellQuoted(marketplace.path))
        claude plugin install \(pluginID)
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
