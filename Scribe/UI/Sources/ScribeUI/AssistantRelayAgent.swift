import Foundation
import ScribeMCPCore

/// Keeps the outbound relay connection alive only while Scribe is running.
@MainActor
public final class AssistantRelayAgent: ObservableObject {
    public enum State: Equatable, Sendable {
        case stopped, connecting, connected
        case retrying(String), failed(String)
    }

    public static let shared = AssistantRelayAgent()
    public static let enabledKey = "scribe.settings.assistantRelayConnected"
    public static let relayAddressKey = "scribe.settings.assistantRelayAddress"
    public static let defaultRelayOrigin = "https://scribe.ovld.ai"
    public static let linkURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Scribe/MCP/relay.json")
    public static var isLinked: Bool { FileManager.default.fileExists(atPath: linkURL.path) }

    @Published public private(set) var state: State = .stopped
    private var connection: Task<Void, Never>?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    public func resumeIfEnabled(package: AssistantConnectorPackage) {
        let text = defaults.string(forKey: Self.relayAddressKey) ?? package.packagedRelay?.origin ?? Self.defaultRelayOrigin
        guard isEnabled, state == .stopped, let relay = try? AssistantServerAddress.parse(text).get() else { return }
        start(package: package, relay: relay)
    }

    public func start(package: AssistantConnectorPackage, relay: AssistantServerAddress) {
        defaults.set(true, forKey: Self.enabledKey)
        halt()
        state = .connecting
        let client = package.relayClient()
        connection = Task { [weak self] in
            do {
                try await client.link(origin: relay.origin)
                try await client.run { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.isEnabled else { return }
                        self.state = message == "connected" ? .connected : .retrying(message)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? RelayFailure)?.status == 401 || error.localizedDescription.contains("Already linked") {
                    self.defaults.set(false, forKey: Self.enabledKey)
                }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    public func stop() {
        defaults.set(false, forKey: Self.enabledKey)
        halt()
        state = .stopped
    }

    public func halt() {
        connection?.cancel()
        connection = nil
    }
}
