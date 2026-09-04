import Foundation
import ScribeAppCore
import XCTest
@testable import Transcription

final class WorkerClientTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scribe Worker Client \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Message exchange

    func testHandshakeAndRunStreamEveryStageWithItsResultFile() async throws {
        let client = try makeClient(FakeTranscriptionWorker.healthyRun())

        let handshake = try await client.handshake()
        XCTAssertEqual(handshake.protocolVersion, WorkerEnvelope.currentVersion)
        XCTAssertEqual(handshake.workerVersion, "fake-1.0")
        XCTAssertTrue(handshake.networkingDisabled)
        XCTAssertTrue(handshake.runtimeDownloadsDisabled)
        XCTAssertTrue(handshake.telemetryDisabled)

        let runDirectory = root.appending(path: "run", directoryHint: .isDirectory)
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: runDirectory))

        var progressStages: [String] = []
        var results: [WorkerStageResult] = []
        var finished = false
        while !finished {
            switch try await client.nextRunEvent() {
            case let .progress(progress): progressStages.append(progress.stage)
            case let .stageResult(result): results.append(result)
            case .finished: finished = true
            }
        }
        await client.shutdown()

        XCTAssertEqual(progressStages, ["prepare", "transcribe", "diarize", "embed"])
        XCTAssertEqual(results.map(\.stage), ["prepare", "transcribe", "diarize", "embed"])
        // Large data stays on disk: a result names a file, it does not carry one.
        XCTAssertEqual(results.map(\.resultFileName), ["prepare.json", "transcript.json", "diarization.json", "embeddings.json"])
    }

    func testAnEnvelopeVersionTheHostDoesNotSupportIsRefused() async throws {
        let unsupported = #"{"version":2,"kind":"stage_result","requestID":"%s","payload":{"stage":"handshake"}}"#
        let client = try makeClient(FakeTranscriptionWorker(handshakeRecord: unsupported, steps: []))

        let failure = await failure(of: { _ = try await client.handshake() })
        XCTAssertEqual(failure.code, WorkerFailure.protocolErrorCode)
        XCTAssertTrue(failure.message.contains("version 2"), failure.message)
    }

    func testAMalformedRecordIsRefusedRatherThanIgnored() async throws {
        let client = try makeClient(FakeTranscriptionWorker(handshakeRecord: "this is not JSON", steps: []))

        let failure = await failure(of: { _ = try await client.handshake() })
        XCTAssertEqual(failure.code, WorkerFailure.protocolErrorCode)
    }

    // MARK: - Message-size bounds

    func testAnInboundRecordOverTheProtocolLimitIsRefused() async throws {
        let oversize = root.appending(path: "oversize.json")
        try Data(repeating: UInt8(ascii: "x"), count: WorkerWireFormat.maximumMessageBytes + 64).write(to: oversize)
        let client = try makeClient(FakeTranscriptionWorker(steps: [.emitContentsOfFile(oversize)]))
        try await client.handshake()
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: root))

        let failure = await failure(of: { _ = try await client.nextRunEvent() })
        XCTAssertEqual(failure.code, WorkerFailure.protocolErrorCode)
        XCTAssertTrue(failure.message.contains("\(WorkerWireFormat.maximumMessageBytes)"), failure.message)
        let running = await client.isRunning
        XCTAssertFalse(running, "an oversize record must end the helper rather than leave it streaming")
    }

    func testAnOutboundRecordOverTheProtocolLimitIsRefusedBeforeItIsSent() throws {
        let envelope = WorkerEnvelope(
            kind: .request,
            requestID: "oversize",
            payload: .object(["operation": .string(String(repeating: "x", count: WorkerWireFormat.maximumMessageBytes))])
        )
        XCTAssertThrowsError(try WorkerWireFormat.encode(envelope)) { error in
            guard case let WorkerWireFormatError.messageTooLarge(_, limit) = error else {
                return XCTFail("Expected a structured size error, got \(error)")
            }
            XCTAssertEqual(limit, WorkerWireFormat.maximumMessageBytes)
        }
    }

    // MARK: - Crashes, timeouts, and cancellation

    func testAHelperThatDiesMidStageFailsStructurallyAndKeepsEarlierCheckpoints() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .emit(kind: "progress", payload: #"{"stage":"transcribe","state":"started"}"#),
            .crash,
        ])
        let client = try makeClient(worker)
        try await client.handshake()
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: root))

        let preparedStage = try await stage(of: client)
        XCTAssertEqual(preparedStage, "prepare")
        _ = try await client.nextRunEvent() // the transcribe progress record

        let failure = await failure(of: { _ = try await client.nextRunEvent() })
        XCTAssertEqual(failure.code, WorkerFailure.crashedCode)
        XCTAssertEqual(failure.stage, "transcribe")
        XCTAssertEqual(failure.completedStages, ["prepare"])
        XCTAssertTrue(failure.checkpointsPreserved, "the prepare checkpoint was committed before the crash")
        XCTAssertEqual(failure.diagnostic.code, "transcription.worker.worker_crashed")
    }

    func testASilentHelperTimesOutAndIsTerminated() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .pauseSeconds(30),
        ])
        let client = try makeClient(worker, responseTimeout: .milliseconds(400))
        try await client.handshake()
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: root))
        let preparedStage = try await stage(of: client)
        XCTAssertEqual(preparedStage, "prepare")

        let failure = await failure(of: { _ = try await client.nextRunEvent() })
        XCTAssertEqual(failure.code, WorkerFailure.timedOutCode)
        XCTAssertEqual(failure.completedStages, ["prepare"])
        XCTAssertTrue(failure.checkpointsPreserved)
        let running = await client.isRunning
        XCTAssertFalse(running, "a wedged helper must not be left holding models while capture needs memory")
    }

    func testCancellationReachesTheHelperAndPreservesCommittedStages() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .awaitRecord,
            .emit(kind: "stage_result", payload: #"{"stage":"cancel","accepted":true}"#),
            .emit(kind: "error", payload: #"{"code":"cancelled","message":"Cancelled at a stage boundary.","details":{"stage":"prepare","checkpointsPreserved":true}}"#),
        ])
        let client = try makeClient(worker)
        try await client.handshake()
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: root))
        let preparedStage = try await stage(of: client)
        XCTAssertEqual(preparedStage, "prepare")

        await client.requestCancellation()
        let failure = await failure(of: { _ = try await client.nextRunEvent() })
        XCTAssertTrue(failure.isCancellation)
        XCTAssertEqual(failure.stage, "prepare")
        XCTAssertTrue(failure.checkpointsPreserved)
        await client.shutdown()
    }

    func testCancellingTheAwaitingTaskAsksTheHelperToStopAtItsBoundary() async throws {
        let worker = FakeTranscriptionWorker(steps: [
            .emit(kind: "stage_result", payload: #"{"stage":"prepare","status":"complete","resultPath":"prepare.json"}"#),
            .awaitRecord,
            .emit(kind: "error", payload: #"{"code":"cancelled","message":"Cancelled at a stage boundary.","details":{"stage":"prepare","checkpointsPreserved":true}}"#),
        ])
        let client = try makeClient(worker)
        try await client.handshake()
        try await client.startRun(.init(sourceURL: root.appending(path: "source.wav"), runDirectoryURL: root))
        let preparedStage = try await stage(of: client)
        XCTAssertEqual(preparedStage, "prepare")

        let waiting = Task { try await client.nextRunEvent() }
        // Give the task time to reach its suspension point before cancelling it.
        try await Task.sleep(for: .milliseconds(200))
        waiting.cancel()

        let failure = await failure(of: { _ = try await waiting.value })
        XCTAssertTrue(failure.isCancellation)
        XCTAssertTrue(failure.checkpointsPreserved)
        await client.shutdown()
    }

    // MARK: - Locating the helper

    func testTheHelperIsFoundInsideTheApplicationBundle() throws {
        let bundleURL = root.appending(path: "Scribe.app", directoryHint: .isDirectory)
        let helpers = bundleURL.appending(path: "Contents/Library/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appending(path: WorkerLocator.helperName)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let candidates = WorkerLocator.searchPaths(in: Bundle(url: bundleURL) ?? .main)
        XCTAssertEqual(candidates.first?.path, helper.path)
    }

    func testAnEnvironmentOverrideWinsAndAMissingHelperIsAStructuredError() throws {
        let helper = root.appending(path: "OverriddenWorker")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let located = try WorkerLocator.locate(
            environment: [WorkerLocator.executablePathEnvironmentKey: helper.path, WorkerLocator.modelsDirectoryEnvironmentKey: root.path]
        )
        XCTAssertEqual(located.executableURL.path, helper.path)
        XCTAssertEqual(located.arguments, ["--models-directory", root.path])

        XCTAssertThrowsError(try WorkerLocator.locate(environment: [WorkerLocator.executablePathEnvironmentKey: root.appending(path: "absent").path])) { error in
            guard case WorkerLocatorError.helperNotExecutable = error else {
                return XCTFail("Expected a structured locator error, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func makeClient(_ worker: FakeTranscriptionWorker, responseTimeout: Duration = .seconds(20)) throws -> WorkerClient {
        let installation = try worker.install(in: root.appending(path: "helper-\(UUID().uuidString)", directoryHint: .isDirectory))
        return WorkerClient(configuration: .init(installation: installation, responseTimeout: responseTimeout, terminationGracePeriod: .milliseconds(200)))
    }

    private func stage(of client: WorkerClient) async throws -> String? {
        guard case let .stageResult(result) = try await client.nextRunEvent() else { return nil }
        return result.stage
    }

    private func failure(of operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> WorkerFailure {
        do {
            try await operation()
            XCTFail("Expected a structured worker failure", file: file, line: line)
        } catch let failure as WorkerFailure {
            return failure
        } catch {
            XCTFail("Expected a structured worker failure, got \(error)", file: file, line: line)
        }
        return WorkerFailure(code: "unreachable", message: "unreachable")
    }
}
