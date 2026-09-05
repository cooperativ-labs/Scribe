import Platform
import SwiftUI

struct TranscriptionModelSettingsView: View {
    @ObservedObject var settings: ScribeSettings
    @ObservedObject var installer: TranscriptionModelInstaller
    @State private var choosingFolder = false
    @State private var folderError: String?

    var body: some View {
        Section("Transcription model") {
            LabeledContent("Model", value: "Parakeet v3 · Recommended")
            Text("Runs locally on your Mac. Downloads about 505 MB from Hugging Face, including the speaker detection models needed for transcription.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LabeledContent("Models folder") {
                Text(settings.modelsFolderURL.path)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose Models Folder…") { choosingFolder = true }
                Button("Use Default") {
                    selectFolder(ScribeSettings.defaultModelsFolderURL)
                }
                .disabled(settings.modelsFolderURL == ScribeSettings.defaultModelsFolderURL)
            }
            .disabled(installer.isBusy)
            Text("Changing folders leaves existing downloads in their original location.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            switch installer.state {
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking installed models…") }
            case .installed:
                Label("Installed · Ready to transcribe", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installing:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(installer.completedBytes), total: Double(max(1, installer.totalBytes)))
                        .accessibilityLabel("Model installation")
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Downloading and verifying models…")
                    }
                    Text("\(ByteCountFormatter.string(fromByteCount: installer.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: installer.totalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel Download") { installer.cancel() }
                }
            case .notInstalled:
                Text("Install the model to enable transcription.").foregroundStyle(.secondary)
                installButton("Install Model")
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                installButton("Retry Installation")
            }
            if let error = folderError ?? settings.modelsFolderError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Link("Parakeet v3 on Hugging Face · CC BY 4.0", destination: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")!)
                .font(.footnote)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): selectFolder(url)
            case .failure(let error): folderError = error.localizedDescription
            }
        }
    }

    private func installButton(_ title: String) -> some View {
        Button(title) { installer.install(directory: settings.modelsFolderURL) }
            .buttonStyle(.borderedProminent)
    }

    private func selectFolder(_ url: URL) {
        do { try settings.setModelsFolder(url); folderError = nil }
        catch { folderError = error.localizedDescription }
    }
}
