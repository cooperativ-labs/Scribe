import AppKit
import Platform
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// For inline settings feedback that has no shared notification center.
    func captureDebugMessage(_ message: String?, source: String, level: MessageDebugEntry.Level = .error) -> some View {
        onChange(of: message, initial: true) { _, message in
            if let message { MessageDebugLog.shared.record(message, source: source, level: level) }
        }
    }
}

struct MessageDebuggingSection: View {
    @ObservedObject var log: MessageDebugLog = .shared
    @State private var showsHistory = false

    var body: some View {
        Section("Debugging") {
            Toggle("Capture messages for debugging", isOn: $log.isEnabled)
            Text("Keep the latest 1,000 status messages, warnings, errors, and dictation events on this Mac, including Secure Keyboard Entry changes. History survives restarting Scribe. Audio, dictated text, live previews, and assistant answers are excluded. Messages may include app names, filenames, or error details.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("View Captured Messages…") { showsHistory = true }
            if let error = log.storageError {
                Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showsHistory) { MessageDebuggingView(log: log) }
    }
}

struct MessageDebuggingView: View {
    @ObservedObject var log: MessageDebugLog
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showsExporter = false
    @State private var showsClearConfirmation = false
    @State private var exportDocument = MessageLogDocument(text: "")
    @State private var exportError: String?

    private var matchingEntries: [MessageDebugEntry] {
        log.entries.reversed().filter {
            search.isEmpty || "\($0.source) \($0.level.rawValue) \($0.message) \($0.context ?? "")"
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Captured Messages").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Toggle("Capture messages for debugging", isOn: $log.isEnabled)
            Text("\(log.entries.count) of 1,000 messages · Newest first · \(log.isEnabled ? "Capturing" : "Capture is off")")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search messages or Secure Keyboard Entry", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search captured messages")
            List {
                if matchingEntries.isEmpty {
                    Text(log.entries.isEmpty ? "Enable capture, then reproduce the flashing warning. Messages will appear here." : "No matching messages.")
                        .foregroundStyle(.secondary)
                }
                ForEach(matchingEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute().second().secondFraction(.fractional(3)))
                            Text("\(entry.source) · \(entry.level.rawValue)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(entry.message)
                        if let context = entry.context {
                            Text(context).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
            }
            if let error = log.storageError ?? exportError {
                Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.exportText(), forType: .string)
                }
                .disabled(log.entries.isEmpty)
                Button("Export…") {
                    exportDocument = MessageLogDocument(text: log.exportText())
                    showsExporter = true
                }
                .disabled(log.entries.isEmpty)
                Spacer()
                Button("Clear History…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(log.entries.isEmpty)
            }
            Text("Copy and export include the full history. Turning capture off keeps existing messages until you clear them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .plainText,
                      defaultFilename: "Scribe-Messages.txt") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
            else { exportError = nil }
        }
        .confirmationDialog("Clear all captured messages?", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { log.clear() }
        } message: {
            Text("This removes the saved history from this Mac. Capture continues if it is enabled.")
        }
    }
}

private struct MessageLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
