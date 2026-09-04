import Platform
import SwiftUI

/// The compact settings pane used by the menu-bar app.
public struct ScribeSettingsView: View {
    @ObservedObject private var settings: ScribeSettings
    @State private var isChoosingRecordingsFolder = false
    @State private var folderSelectionError: String?

    public init(settings: ScribeSettings) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Folder") {
                    Text(settings.recordingsFolderURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Folder…") {
                    isChoosingRecordingsFolder = true
                }
                if let folderSelectionError {
                    Text(folderSelectionError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Remembered sources") {
                TextField("Application bundle ID", text: optionalStringBinding(\.rememberedApplicationBundleIdentifier))
                TextField("Microphone ID", text: optionalStringBinding(\.rememberedMicrophoneID))
            }

            Section("Global shortcuts") {
                Picker("Start recording", selection: $settings.startShortcut) {
                    ForEach(GlobalShortcut.commonChoices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Picker("Stop recording", selection: $settings.stopShortcut) {
                    ForEach(GlobalShortcut.commonChoices) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                Text("Choose different shortcuts for starting and stopping. If another app already owns one, Scribe will show the conflict and keep its menu commands available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Processing") {
                Toggle("Transcribe when the final recording is ready", isOn: $settings.transcribeWhenFinalRecordingIsReady)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fileImporter(
            isPresented: $isChoosingRecordingsFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try settings.setRecordingsFolder(url)
                    folderSelectionError = nil
                } catch {
                    folderSelectionError = error.localizedDescription
                }
            case .failure(let error):
                folderSelectionError = error.localizedDescription
            }
        }
    }

    private func optionalStringBinding(_ keyPath: ReferenceWritableKeyPath<ScribeSettings, String?>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] ?? "" },
            set: { settings[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
