import Platform
import SwiftUI

/// The Assistants tab, in two labelled halves that must not blur: Voice
/// Assistant sends the person's own text out to a model on their account;
/// Transcript Access lets a model in to read their meeting library.
///
/// A segmented control rather than two stacked groups, because each half has
/// its own status row that reads best as the first thing on screen, and the
/// connector half is already several sections long. The choice is remembered.
public struct AssistantSettingsView: View {
    @ObservedObject private var settings: ScribeSettings
    @ObservedObject private var package: AssistantConnectorPackage
    private let permissions: PermissionService?
    private let showDictation: () -> Void
    @ObservedObject private var account: VoiceAssistantAccount

    public init(
        settings: ScribeSettings,
        package: AssistantConnectorPackage,
        permissions: PermissionService? = nil,
        account: VoiceAssistantAccount = .shared,
        showDictation: @escaping () -> Void = {}
    ) {
        self.account = account
        self.settings = settings
        self.package = package
        self.permissions = permissions
        self.showDictation = showDictation
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Assistants", selection: $settings.assistantsPane) {
                ForEach(AssistantsPane.allCases, id: \.self) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(settings.assistantsPane.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 6)

            switch settings.assistantsPane {
            case .voiceAssistant:
                VoiceAssistantSettingsView(
                    settings: settings,
                    modelInstaller: settings.modelInstaller,
                    account: account,
                    permissions: permissions,
                    showDictation: showDictation
                )
            case .transcriptAccess:
                TranscriptAccessSettingsView(package: package)
            }
        }
    }
}

extension AssistantsPane {
    var title: String {
        switch self {
        case .voiceAssistant: "Voice Assistant"
        case .transcriptAccess: "Transcript Access"
        }
    }

    var summary: String {
        switch self {
        case .voiceAssistant: "Hold a key, say what you want, and Scribe writes it where your cursor is, using the text in front of you."
        case .transcriptAccess: "Let Claude Code, ChatGPT and Claude read your meeting transcripts."
        }
    }
}
