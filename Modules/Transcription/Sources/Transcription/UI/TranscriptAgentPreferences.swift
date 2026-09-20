import Foundation

/// What the send sheet remembers between sendings: the agent last used, the
/// models typed for each agent, each agent's effort, and the MCP URL.
///
/// Model names are free text because every agent names its models differently
/// and new ones appear faster than Scribe ships. The history is what makes free
/// text bearable: the last few names typed for an agent are one click away, and
/// the most recent one is where the field starts.
public struct TranscriptAgentPreferences: @unchecked Sendable {
    public static let modelHistoryLimit = 10

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastAgentID: TranscriptAgent.ID? {
        get { defaults.string(forKey: Key.lastAgent) }
        nonmutating set { defaults.set(newValue, forKey: Key.lastAgent) }
    }

    public var mcpURL: String {
        get { defaults.string(forKey: Key.mcpURL) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.mcpURL) }
    }

    /// The models sent to this agent, most recent first, without repeats.
    public func modelHistory(for agentID: TranscriptAgent.ID) -> [String] {
        defaults.stringArray(forKey: Key.modelHistory + agentID) ?? []
    }

    /// The model this agent was last sent with. Empty means its own default,
    /// which is remembered too: clearing the field is a choice like any other.
    public func lastModel(for agentID: TranscriptAgent.ID) -> String {
        defaults.string(forKey: Key.lastModel + agentID) ?? modelHistory(for: agentID).first ?? ""
    }

    public func effort(for agentID: TranscriptAgent.ID) -> TranscriptAgentEffort? {
        defaults.string(forKey: Key.effort + agentID).flatMap(TranscriptAgentEffort.init(rawValue:))
    }

    /// Records one sending. An empty model is remembered as the last choice but
    /// never enters the history, which lists names worth picking again.
    public func recordSend(agentID: TranscriptAgent.ID, model: String?, effort: TranscriptAgentEffort?) {
        lastAgentID = agentID
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        defaults.set(model, forKey: Key.lastModel + agentID)
        if !model.isEmpty {
            var history = modelHistory(for: agentID).filter { $0 != model }
            history.insert(model, at: 0)
            defaults.set(Array(history.prefix(Self.modelHistoryLimit)), forKey: Key.modelHistory + agentID)
        }
        if let effort {
            defaults.set(effort.rawValue, forKey: Key.effort + agentID)
        } else {
            defaults.removeObject(forKey: Key.effort + agentID)
        }
    }

    private enum Key {
        static let lastAgent = "scribe.agentHandoff.lastAgent"
        static let mcpURL = "scribe.agentHandoff.mcpURL"
        static let modelHistory = "scribe.agentHandoff.modelHistory."
        static let lastModel = "scribe.agentHandoff.lastModel."
        static let effort = "scribe.agentHandoff.effort."
    }
}
