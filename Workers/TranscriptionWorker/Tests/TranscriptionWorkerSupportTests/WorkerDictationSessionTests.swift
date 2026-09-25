import Foundation
import Testing
@testable import TranscriptionWorkerSupport

struct WorkerDictationSessionTests {
    @Test func invalidPathDoesNotLoadModels() async {
        let session = WorkerDictationSession(configuration: .init(
            manifestURL: URL(fileURLWithPath: "/missing/manifest.json"),
            modelsDirectory: URL(fileURLWithPath: "/missing/models")
        ))
        var responses: [WorkerEnvelope] = []
        await session.handle(operation: "dictate", requestID: "invalid", payload: [
            "audioPath": .string("relative.wav"),
            "runDirectory": .string("/private/tmp"),
        ]) { responses.append($0) }
        #expect(responses.count == 1)
        #expect(responses.first?.kind == .error)
        #expect(responses.first?.payload.objectValue?["code"]?.stringValue == "dictation_failed")
    }

    @Test func unloadIsIdempotentWithoutModels() async {
        let session = WorkerDictationSession(configuration: .init(
            manifestURL: URL(fileURLWithPath: "/missing/manifest.json"),
            modelsDirectory: URL(fileURLWithPath: "/missing/models")
        ))
        var responses: [WorkerEnvelope] = []
        await session.handle(operation: "unload", requestID: "unload", payload: [:]) { responses.append($0) }
        #expect(responses.first?.kind == .stageResult)
        #expect(responses.first?.payload.objectValue?["stage"]?.stringValue == "unload")
    }
}
