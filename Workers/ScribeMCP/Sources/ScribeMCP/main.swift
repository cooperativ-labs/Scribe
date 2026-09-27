import Foundation
import MCP
import ScribeMCPCore
import Transcription

// scribe-mcp: Scribe's read-only transcript tools over stdio. Reads the library
// in SCRIBE_TRANSCRIPTS_DIR, or the app's default store. stdout carries only MCP.
let directory = ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
let store = TranscriptStore(storeDirectoryURL: directory.map { URL(filePath: $0, directoryHint: .isDirectory) }
    ?? TranscriptStore.defaultStoreDirectoryURL())
let server = await ScribeServer.make(library: TranscriptLibrary(store: store))
do {
    try await server.start(transport: ServerInfoTransport(StdioTransport()))
    await server.waitUntilCompleted()
} catch {
    FileHandle.standardError.write(Data("Scribe MCP: \(error.localizedDescription)\n".utf8))
    exit(1)
}
