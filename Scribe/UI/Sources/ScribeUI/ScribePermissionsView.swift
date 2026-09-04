import Platform
import SwiftUI

/// The first-run permission window.
///
/// macOS prompts for each permission only once, so after a denial the only way
/// forward is System Settings. Every blocking permission therefore always offers
/// that route, whether or not an in-app prompt is still possible.
public struct ScribePermissionsView: View {
    @ObservedObject private var model: RecorderMenuModel
    private let dismiss: () -> Void

    public init(model: RecorderMenuModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scribe records meeting audio locally")
                .font(.title3.weight(.semibold))

            if let prompt = model.presentation.permissionPrompt {
                Text(prompt.title)
                    .font(.headline)
                ForEach(prompt.requirements) { requirement in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(requirement.pane.displayName, systemImage: "lock.shield")
                            .font(.subheadline.weight(.medium))
                        Text(requirement.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Open \(requirement.pane.displayName) Settings") {
                            model.openSystemSettings(requirement.pane)
                        }
                    }
                }
                HStack {
                    if prompt.canRequestInApp {
                        Button("Request Access") { model.requestPermissions() }
                            .keyboardShortcut(.defaultAction)
                    }
                    Spacer()
                    Button("Continue Without Recording", action: dismiss)
                }
            } else {
                Label("Scribe has everything it needs to record.", systemImage: "checkmark.circle")
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
