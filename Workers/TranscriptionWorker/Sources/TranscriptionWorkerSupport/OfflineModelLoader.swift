@preconcurrency import CoreML
import FluidAudio
import Foundation

/// The only model-loading entry point for the worker. It constructs FluidAudio
/// model values from files the host explicitly staged; it intentionally never
/// calls `AsrModels.download`, `downloadAndLoad`, `DownloadUtils`, or a cache
/// convenience API that may attempt recovery by downloading.
public enum OfflineModelLoader {
    public struct LoadedModels: Sendable {
        public let asr: AsrModels
        public let diarization: OfflineDiarizerModels
    }

    public static func load(manifest: ModelManifest, modelsDirectory: URL) async throws -> LoadedModels {
        let asr = try await loadASR(manifest: manifest, modelsDirectory: modelsDirectory)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true

        let diarizationDirectory = modelsDirectory.appending(path: "speaker-diarization-coreml", directoryHint: .isDirectory)
        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly
        let diarization = OfflineDiarizerModels(
            segmentationModel: try loadModel(diarizationDirectory.appending(path: "Segmentation.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            fbankModel: try loadModel(diarizationDirectory.appending(path: "FBank.mlmodelc", directoryHint: .isDirectory), configuration: fbankConfiguration),
            embeddingModel: try loadModel(diarizationDirectory.appending(path: "Embedding.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            pldaRhoModel: try loadModel(diarizationDirectory.appending(path: "PldaRho.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            pldaPsi: try loadPLDAPsi(from: diarizationDirectory.appending(path: "plda-parameters.json")),
            compilationDuration: 0
        )
        return LoadedModels(asr: asr, diarization: diarization)
    }

    /// Loads only the Parakeet models from explicitly staged paths.  This is
    /// intentionally separate from the combined loader: ASR can be released
    /// before the later diarization stage without ever using FluidAudio's
    /// download/cache helpers.
    public static func loadASR(
        manifest: ModelManifest,
        modelsDirectory: URL,
        computeUnits: ASRComputeUnits = .cpuAndNeuralEngine,
        allowLowPrecisionAccumulationOnGPU: Bool = true
    ) async throws -> AsrModels {
        let report = manifest.validate(modelsDirectory: modelsDirectory)
        guard report.isValid else { throw ModelSetupError.report(report) }
        guard !manifest.telemetry.enabled, !manifest.telemetry.runtimeDownloadsAllowed else {
            throw ModelSetupError.unsafeManifest
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreMLValue
        configuration.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionAccumulationOnGPU

        let asrDirectory = modelsDirectory.appending(path: "parakeet-tdt-0.6b-v3-coreml", directoryHint: .isDirectory)
        let vocabulary = try loadVocabulary(from: asrDirectory.appending(path: "parakeet_vocab.json"))
        return AsrModels(
            encoder: try loadModel(asrDirectory.appending(path: "Encoder.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            preprocessor: try loadModel(asrDirectory.appending(path: "Preprocessor.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            decoder: try loadModel(asrDirectory.appending(path: "Decoder.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            joint: try loadModel(asrDirectory.appending(path: "JointDecision.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
    }

    /// Loads only the offline diarization stack from the staged model bundle.
    /// Keeping this separate from `load` lets the worker release ASR before it
    /// starts global clustering, and—more importantly—never reaches
    /// `OfflineDiarizerManager.prepareModels()`, whose recovery path may fetch
    /// missing models.
    public static func loadDiarization(
        manifest: ModelManifest,
        modelsDirectory: URL,
        computeUnits: ASRComputeUnits = .cpuAndNeuralEngine,
        allowLowPrecisionAccumulationOnGPU: Bool = true
    ) throws -> OfflineDiarizerModels {
        let report = manifest.validate(modelsDirectory: modelsDirectory)
        guard report.isValid else { throw ModelSetupError.report(report) }
        guard !manifest.telemetry.enabled, !manifest.telemetry.runtimeDownloadsAllowed else {
            throw ModelSetupError.unsafeManifest
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreMLValue
        configuration.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionAccumulationOnGPU

        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly

        let directory = modelsDirectory.appending(path: "speaker-diarization-coreml", directoryHint: .isDirectory)
        return OfflineDiarizerModels(
            segmentationModel: try loadModel(directory.appending(path: "Segmentation.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            fbankModel: try loadModel(directory.appending(path: "FBank.mlmodelc", directoryHint: .isDirectory), configuration: fbankConfiguration),
            embeddingModel: try loadModel(directory.appending(path: "Embedding.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            pldaRhoModel: try loadModel(directory.appending(path: "PldaRho.mlmodelc", directoryHint: .isDirectory), configuration: configuration),
            pldaPsi: try loadPLDAPsi(from: directory.appending(path: "plda-parameters.json")),
            compilationDuration: 0
        )
    }

    private static func loadModel(_ url: URL, configuration: MLModelConfiguration) throws -> MLModel {
        try MLModel(contentsOf: url, configuration: configuration)
    }

    private static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    private static func loadPLDAPsi(from url: URL) throws -> [Double] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let tensors = root?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let data = Data(base64Encoded: encoded), data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw ModelSetupError.invalidPLDAParameters(url.path)
        }
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self)).map(Double.init)
        }
    }
}

/// Stable, JSON-friendly compute-unit choices used by the worker manifest and
/// benchmark reports.  Do not expose Core ML's raw values in the protocol.
public enum ASRComputeUnits: String, Codable, Sendable, CaseIterable {
    case cpuOnly
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all

    fileprivate var coreMLValue: MLComputeUnits {
        switch self {
        case .cpuOnly: .cpuOnly
        case .cpuAndGPU: .cpuAndGPU
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .all: .all
        }
    }
}

public enum ModelSetupError: Error, LocalizedError, Sendable {
    case report(AssetValidationReport)
    case unsafeManifest
    case invalidPLDAParameters(String)

    public var errorDescription: String? {
        switch self {
        case let .report(report): "Offline model setup is incomplete at \(report.modelsDirectory)."
        case .unsafeManifest: "The worker refuses a manifest that permits telemetry or runtime model downloads."
        case let .invalidPLDAParameters(path): "PLDA parameters are invalid at \(path)."
        }
    }
}
