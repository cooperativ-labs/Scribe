import Foundation
import Security
// The macOS 27 SDK ships FoundationModels 2, the first with
// PrivateCloudComputeLanguageModel; an older SDK builds without this account.
#if canImport(FoundationModels, _version: 2)
import FoundationModels
#endif

/// Apple's server model behind Apple Intelligence, run on Private Cloud
/// Compute (macOS 27 and later, with Apple Intelligence turned on). The
/// request leaves the Mac for Apple's attested servers, which keep nothing;
/// there is no key or bill, but each person has a usage quota. Its context
/// window is several times the on-device model's, so long screen text is
/// shortened far less.
///
/// Apple grants the model only to apps signed with the
/// `com.apple.developer.private-cloud-compute` entitlement; without it the
/// system refuses the session, so `PrivateCloudModel.status` says so before
/// any request is made.
public struct PrivateCloudAssistant: TextAssistant {
    /// Tokens kept free for the answer.
    static let reservedResponseTokens = 2_048
    /// Characters per token assumed when sizing the prompt; the model offers
    /// no token count, and a model that finds the prompt too long says by how
    /// much, so the estimate is corrected once from that.
    static let estimatedCharactersPerToken = 3

    public let displayName = "Apple Private Cloud Compute"
    public var systemPrompt: String?

    public init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27.0, *) else { throw AssistError.appleModel(PrivateCloudModel.Status.unsupportedSystem.message) }
        let status = PrivateCloudModel.status
        guard status == .available else { throw AssistError.appleModel(status.message) }

        let model = PrivateCloudComputeLanguageModel()
        let instructions = AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName)
        let contextSize = (try? await model.contextSize) ?? Self.fallbackContextSize
        var characters = Self.characterBudget(contextSize: contextSize, instructions: instructions)
        for attempt in 0..<2 {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let input = AssistPrompt.input(for: request.trimmed(toCharacters: characters))
            do {
                let response = try await session.respond(to: input, options: GenerationOptions(maximumResponseTokens: Self.reservedResponseTokens))
                guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistError.emptyResponse }
                return AssistResponse(text: response.content, model: displayName)
            } catch LanguageModelError.contextSizeExceeded(let exceeded) where attempt == 0 && exceeded.tokenCount > 0 && characters > 0 {
                characters = Self.shrunk(characters, contextSize: exceeded.contextSize, tokenCount: exceeded.tokenCount)
            } catch {
                throw Self.assistError(for: error)
            }
        }
        throw AssistError.appleModel("The screen text is too long for Private Cloud Compute. Select less text and try again.")
        #else
        throw AssistError.appleModel(PrivateCloudModel.Status.unsupportedSystem.message)
        #endif
    }

    /// The context size assumed when the system cannot report it.
    static let fallbackContextSize = 32_768

    /// Characters of source text that fit beside the instructions and the answer.
    static func characterBudget(contextSize: Int, instructions: String) -> Int {
        let tokens = contextSize - reservedResponseTokens - instructions.count / estimatedCharactersPerToken
        return max(0, tokens * estimatedCharactersPerToken)
    }

    /// The budget cut in proportion to how far the prompt overran, less a
    /// tenth for the instructions and the answer the overrun did not count.
    static func shrunk(_ characters: Int, contextSize: Int, tokenCount: Int) -> Int {
        let usable = max(0, contextSize - reservedResponseTokens)
        return max(0, Int(Double(characters) * Double(usable) / Double(tokenCount) * 0.9))
    }

    #if canImport(FoundationModels, _version: 2)
    /// What to tell the person when a request fails.
    @available(macOS 27.0, *)
    static func assistError(for error: Error) -> Error {
        switch error {
        case let error as AssistError:
            return error
        case is CancellationError:
            return CancellationError()
        case PrivateCloudComputeLanguageModel.Error.quotaLimitReached(let limit):
            return AssistError.appleModel(PrivateCloudModel.limitMessage(resetsAt: limit.resetDate))
        case PrivateCloudComputeLanguageModel.Error.networkFailure:
            return AssistError.network("Could not reach Apple’s Private Cloud Compute. Check your internet connection.")
        case PrivateCloudComputeLanguageModel.Error.serviceUnavailable:
            return AssistError.appleModel("Apple’s Private Cloud Compute is unavailable right now. Try again shortly.")
        case LanguageModelError.rateLimited(let limited):
            return AssistError.appleModel(PrivateCloudModel.limitMessage(resetsAt: limited.resetDate))
        default:
            // Refusals, guardrails and timeouts describe themselves.
            return AssistError.appleModel(error.localizedDescription)
        }
    }
    #endif
}

/// Whether Private Cloud Compute can take a request, for Settings.
public enum PrivateCloudModel {
    /// The entitlement Apple grants on request; the system refuses unsigned apps.
    public static let entitlement = "com.apple.developer.private-cloud-compute"

    public enum Status: Sendable, Equatable {
        case available
        /// Older than macOS 27, or built without the macOS 27 SDK.
        case unsupportedSystem
        case deviceNotEligible
        /// Apple Intelligence is off or still setting up.
        case systemNotReady
        /// This build is not signed with Apple's Private Cloud Compute entitlement.
        case notEntitled
        /// The person's quota is used up; `resetsAt` when the system said.
        case limitReached(resetsAt: Date?)

        public var message: String {
            switch self {
            case .available: "Apple’s Private Cloud Compute model is ready."
            case .unsupportedSystem: "Private Cloud Compute needs macOS 27 or later."
            case .deviceNotEligible: "This Mac does not support Apple Intelligence."
            case .systemNotReady: "Turn on Apple Intelligence in System Settings to use Private Cloud Compute. If it is on, it may still be setting up."
            case .notEntitled: "This copy of Scribe is not approved by Apple to use Private Cloud Compute. Choose another account."
            case .limitReached(let resetsAt): PrivateCloudModel.limitMessage(resetsAt: resetsAt)
            }
        }
    }

    public static var status: Status {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27.0, *) else { return .unsupportedSystem }
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available: break
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.systemNotReady): return .systemNotReady
        @unknown default: return .systemNotReady
        }
        guard isEntitled else { return .notEntitled }
        if case .limitReached = model.quotaUsage.status {
            return .limitReached(resetsAt: model.quotaUsage.resetDate)
        }
        return .available
        #else
        return .unsupportedSystem
        #endif
    }

    /// Whether the person is close to their quota, so Settings can warn.
    public static var isApproachingLimit: Bool {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27.0, *) else { return false }
        if case .belowLimit(let below) = PrivateCloudComputeLanguageModel().quotaUsage.status {
            return below.isApproachingLimit
        }
        return false
        #else
        return false
        #endif
    }

    /// Whether Apple offers the person a way to raise their quota.
    public static var canIncreaseLimit: Bool {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27.0, *) else { return false }
        return PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion != nil
        #else
        return false
        #endif
    }

    /// Shows Apple's offer to raise the quota, when there is one.
    @MainActor
    public static func showLimitIncrease() {
        #if canImport(FoundationModels, _version: 2)
        guard #available(macOS 27.0, *) else { return }
        PrivateCloudComputeLanguageModel().quotaUsage.limitIncreaseSuggestion?.show()
        #endif
    }

    /// Whether this process is signed with the entitlement. Checked up front
    /// because without it the system fails the request with an opaque
    /// "Operation not permitted" (ModelManagerError 1046).
    static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) else { return false }
        return (value as? Bool) ?? true
    }

    static func limitMessage(resetsAt: Date?) -> String {
        guard let resetsAt else { return "You’ve reached your Private Cloud Compute limit. Try again later." }
        return "You’ve reached your Private Cloud Compute limit. It resets at \(resetsAt.formatted(AssistError.resetStyle(for: resetsAt)))."
    }
}
