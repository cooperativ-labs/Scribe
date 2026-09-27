import Platform
import SwiftUI

/// Chooses a dictation or assistant key from the one shared list, with the key
/// the other mode holds greyed out and named ("Right Shift (⇧) (assistant)").
///
/// A `Menu` of toggles rather than a `Picker`: a menu-style `Picker` on macOS
/// does not reliably disable individual rows, and the held key must not be
/// choosable at all. Each toggle shows the native checkmark on the current key.
struct ActivationKeyPicker: View {
    let title: String
    @Binding var selection: DictationActivationKey
    /// The key the other mode uses, and that mode's name for the suffix.
    let heldKey: DictationActivationKey
    let heldBy: String

    var body: some View {
        LabeledContent(title) {
            Menu(selection.displayName) {
                ForEach(DictationActivationKey.allCases) { key in
                    Toggle(isOn: Binding(
                        get: { key == selection },
                        set: { if $0 { selection = key } }
                    )) {
                        Text(key == heldKey ? "\(key.displayName) (\(heldBy))" : key.displayName)
                    }
                    .disabled(key == heldKey)
                }
            }
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue(selection.displayName)
        }
    }
}

/// The consequences of a chosen key, one sentence each, shown under either picker.
struct ActivationKeyNotes: View {
    let key: DictationActivationKey
    /// The other mode's key, which matters only for the Fn + Control chord.
    let otherKey: DictationActivationKey

    var body: some View {
        if key.usesFunctionKey {
            Text("In System Settings → Keyboard, set ‘Press Fn (🌐) key to’ to ‘Do Nothing’ to avoid also opening emoji, switching input sources, or starting Apple Dictation. Some external keyboards handle Fn internally and do not send it to macOS.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if key == .functionControl && otherKey == .function {
            Text("Fn + Control is easiest to use when Fn alone is not the other key: pressing Fn first starts that mode, and adding Control switches to this one.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if key.isTypingModifier {
            Text("\(key.shortName) also types shortcuts and accented characters. A quick press followed by another key is ignored, so typing still works; hold it on its own to start.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// A Microphone or Accessibility permission, with the way to grant it. Shared
/// by Dictation and Voice Assistant, which need the same two.
struct PermissionStatusRow: View {
    let name: String
    let allowed: Bool
    let pane: SystemSettingsPane
    let permissions: PermissionService?

    var body: some View {
        HStack {
            Label("\(name): \(allowed ? "Allowed" : "Not allowed")", systemImage: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
            Spacer()
            if !allowed {
                Button("Open System Settings") { permissions?.openSystemSettings(pane) }
            }
        }
    }
}
