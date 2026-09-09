import Foundation
import ScribeAppCore

/// The durable state of a transcription run. Non-terminal cases are safe
/// boundaries at which a run may be paused, cancelled, or recovered.
public enum TranscriptionJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case preparing
    case transcribing
    case reconcilingTimings
    case diarizing
    case assembling
    case matchingSpeakers
    case complete
    case cancelled
    case failed

    public var isTerminal: Bool {
        self == .complete || self == .cancelled || self == .failed
    }

    public static let processingStages: [Self] = [
        .preparing, .transcribing, .reconcilingTimings, .diarizing,
        .assembling, .matchingSpeakers,
    ]

    public var progressLabel: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing audio"
        case .transcribing: "Transcribing"
        case .reconcilingTimings: "Aligning timings"
        case .diarizing: "Separating speakers"
        case .assembling: "Assembling transcript"
        case .matchingSpeakers: "Matching speakers"
        case .complete: "Complete"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    public var progressFractionOnStart: Double {
        guard let index = Self.processingStages.firstIndex(of: self) else {
            return self == .complete ? 1 : 0
        }
        return Double(index) / Double(Self.processingStages.count)
    }

    public var progressFractionOnCheckpoint: Double {
        guard let index = Self.processingStages.firstIndex(of: self) else {
            return self == .complete ? 1 : 0
        }
        return Double(index + 1) / Double(Self.processingStages.count)
    }
}

/// A completed stage's durable, fingerprinted recovery point.
public struct TranscriptionStageCheckpoint: Codable, Sendable, Equatable {
    public let stage: TranscriptionJobState
    public let sourceFingerprint: String
    public let modelFingerprint: String
    public let configurationFingerprint: String
    public let artifactURL: URL?
    public let completedAt: Date

    public init(
        stage: TranscriptionJobState,
        sourceFingerprint: String,
        modelFingerprint: String,
        configurationFingerprint: String,
        artifactURL: URL? = nil,
        completedAt: Date = Date()
    ) {
        self.stage = stage
        self.sourceFingerprint = sourceFingerprint
        self.modelFingerprint = modelFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.artifactURL = artifactURL
        self.completedAt = completedAt
    }
}

/// The result a stage runner writes after atomically committing its artifact.
public struct TranscriptionStageOutput: Sendable, Equatable {
    public let artifactURL: URL?

    public init(artifactURL: URL? = nil) {
        self.artifactURL = artifactURL
    }
}

/// The worker-facing seam. Queue ownership stays in the coordinator.
public protocol TranscriptionStageRunning: Sendable {
    func run(stage: TranscriptionJobState, job: TranscriptionJob) async throws -> TranscriptionStageOutput
}

/// The persisted contents of `<run>/job.json`.
public struct TranscriptionJob: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let runID: UUID
    public let request: TranscriptionRequest
    public let sourceSnapshotURL: URL
    public let runDirectoryURL: URL
    public let sourceFingerprint: String
    public let modelFingerprint: String
    public let configurationFingerprint: String
    public var state: TranscriptionJobState
    public var checkpoints: [TranscriptionJobState: TranscriptionStageCheckpoint]
    public var failure: TranscriptionDiagnostic?
    public let createdAt: Date
    public var updatedAt: Date
    public var retryOfRunID: UUID?

    public init(
        id: UUID = UUID(),
        runID: UUID = UUID(),
        request: TranscriptionRequest,
        sourceSnapshotURL: URL,
        runDirectoryURL: URL,
        sourceFingerprint: String,
        modelFingerprint: String,
        configurationFingerprint: String,
        state: TranscriptionJobState = .queued,
        checkpoints: [TranscriptionJobState: TranscriptionStageCheckpoint] = [:],
        failure: TranscriptionDiagnostic? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        retryOfRunID: UUID? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.runID = runID
        self.request = request
        self.sourceSnapshotURL = sourceSnapshotURL
        self.runDirectoryURL = runDirectoryURL
        self.sourceFingerprint = sourceFingerprint
        self.modelFingerprint = modelFingerprint
        self.configurationFingerprint = configurationFingerprint
        self.state = state
        self.checkpoints = checkpoints
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.retryOfRunID = retryOfRunID
    }

    public var jobFileURL: URL { runDirectoryURL.appendingPathComponent("job.json") }
}

public enum TranscriptionCoordinatorError: Error, Sendable, Equatable {
    case unknownJob(UUID)
    case sourceSnapshotFailed(String)
    case persistenceFailed(String)
}
