import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model (macOS 26 and later, with Apple
/// Intelligence turned on). Nothing leaves the Mac and nothing is billed, but
/// the model is small and its context window holds only a few thousand
/// tokens, so the source text is cut to fit before the request is made.
public struct AppleIntelligenceAssistant: TextAssistant {
    /// Tokens kept free for the answer.
    static let reservedResponseTokens = 1_024
    /// Characters per token assumed until the system can count them (macOS 26.4).
    static let estimatedCharactersPerToken = 3

    public let displayName = "Apple Intelligence"
    public var systemPrompt: String?

    public init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt
    }

    public func respond(to request: AssistRequest) async throws -> AssistResponse {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw AssistError.appleModel(OnDeviceModel.Status.unsupportedSystem.message) }
        let model = SystemLanguageModel.default
        let status = OnDeviceModel.status
        guard status == .available else { throw AssistError.appleModel(status.message) }

        let instructions = AssistPrompt.system(template: systemPrompt, applicationName: request.applicationName)
        let input = try await fittedInput(for: request, instructions: instructions, model: model)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: input, options: GenerationOptions(maximumResponseTokens: Self.reservedResponseTokens))
            guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistError.emptyResponse }
            return AssistResponse(text: response.content, model: displayName)
        } catch let error as AssistError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // GenerationError on macOS 26, LanguageModelError on 27: both describe themselves.
            throw AssistError.appleModel(error.localizedDescription)
        }
        #else
        throw AssistError.appleModel(OnDeviceModel.Status.unsupportedSystem.message)
        #endif
    }

    #if canImport(FoundationModels)
    /// The prompt with the source text cut until instructions, prompt and the
    /// reserved answer fit the model's context window.
    @available(macOS 26.0, *)
    private func fittedInput(for request: AssistRequest, instructions: String, model: SystemLanguageModel) async throws -> String {
        let budget = model.contextSize - Self.reservedResponseTokens
        var characters = max(0, (budget - instructions.count / Self.estimatedCharactersPerToken) * Self.estimatedCharactersPerToken)
        var input = AssistPrompt.input(for: request.trimmed(toCharacters: characters))
        guard #available(macOS 26.4, *) else { return input }
        // Count for real and shrink by a quarter until it fits.
        for _ in 0..<6 {
            let used = try await model.tokenCount(for: instructions + "\n" + input)
            if used <= budget || characters == 0 { break }
            characters = characters * 3 / 4
            input = AssistPrompt.input(for: request.trimmed(toCharacters: characters))
        }
        return input
    }
    #endif
}

/// Whether Apple's on-device model can take a request, for Settings.
public enum OnDeviceModel {
    public enum Status: Sendable, Equatable {
        case available
        /// Older than macOS 26, or built without the FoundationModels SDK.
        case unsupportedSystem
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        /// Apple Intelligence is on but the model is still downloading.
        case modelNotReady

        public var message: String {
            switch self {
            case .available: "Apple’s on-device model is ready."
            case .unsupportedSystem: "Apple’s on-device model needs macOS 26 or later."
            case .deviceNotEligible: "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings to use the on-device model."
            case .modelNotReady: "Apple Intelligence is still downloading its model. Try again once it finishes."
            }
        }
    }

    public static var status: Status {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupportedSystem }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        @unknown default: return .modelNotReady
        }
        #else
        return .unsupportedSystem
        #endif
    }
}

extension AssistRequest {
    /// The request with at most `limit` characters of source text in all: the
    /// screen is cut first, from the last window back, then the copied text,
    /// then the selection. The instruction is never cut.
    public func trimmed(toCharacters limit: Int) -> AssistRequest {
        var excess = (selectedText?.count ?? 0) + (copiedText?.count ?? 0) + screenText.reduce(0) { $0 + $1.text.count } - max(0, limit)
        guard excess > 0 else { return self }
        var copy = self
        copy.truncated = true
        for index in copy.screenText.indices.reversed() where excess > 0 {
            let cut = min(excess, copy.screenText[index].text.count)
            copy.screenText[index].text = String(copy.screenText[index].text.dropLast(cut))
            excess -= cut
        }
        copy.screenText.removeAll { $0.text.isEmpty }
        if excess > 0, let copied = copy.copiedText {
            let cut = min(excess, copied.count)
            copy.copiedText = String(copied.dropLast(cut))
            excess -= cut
        }
        if excess > 0, let selected = copy.selectedText {
            copy.selectedText = String(selected.dropLast(min(excess, selected.count)))
        }
        return copy
    }
}
