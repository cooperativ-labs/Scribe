import Foundation

/// The public address ChatGPT and Claude use to reach Scribe's connector.
///
/// Both services connect from their own cloud, never from this Mac, so the
/// address has to be an HTTPS origin that a tunnel or reverse proxy forwards to
/// the local bridge. A person may paste the bare host, the origin, or the full
/// `/mcp` endpoint a client showed them; all three name the same server.
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
        case .empty: "Enter the HTTPS address of your tunnel or proxy."
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
    public var steps: [String] {
        switch self {
        case .chatGPT:
            [
                "Start Scribe’s connector server and your HTTPS tunnel.",
                "In ChatGPT, turn on Developer mode in Settings → Security and login.",
                "On the Plugins page, press +, paste the connector URL, name it Scribe, choose OAuth, and create it.",
                "If ChatGPT shows a callback URL, paste it under ChatGPT callback and restart the server with the new command.",
                "Approve the connection on Scribe’s consent page with your owner key.",
                "In a new chat, press + → More → Scribe, then ask for your latest transcript.",
            ]
        case .claude:
            [
                "Start Scribe’s connector server and your HTTPS tunnel. Claude’s callback is already allowed.",
                "In Claude, open Customize → Connectors, press +, then Add custom connector.",
                "Paste the connector URL, name it Scribe, press Add, then Connect.",
                "Approve the connection on Scribe’s consent page with your owner key.",
                "In a chat, press + → Connectors and turn on Scribe. It works in Claude Desktop and mobile too.",
            ]
        case .claudeCode:
            [
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
    public static let marketplaceName = "scribe-local"
    public static let pluginID = "scribe@scribe-local"

    /// The callbacks the server allows: Claude's, plus ChatGPT's once known.
    ///
    /// ChatGPT's callback can be specific to one connection, so it is never
    /// guessed; it is whatever the person copied out of ChatGPT.
    public static func redirectURIs(chatGPTCallback: String) -> [String] {
        var uris = [claudeCallback]
        let callback = chatGPTCallback.trimmingCharacters(in: .whitespacesAndNewlines)
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
