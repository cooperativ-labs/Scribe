import CryptoKit
import FluidAudio
import Foundation

/// What a cached optional asset was loaded from. A retained value is reused only
/// while the models folder, the manifest bytes and every declared file's stamp
/// (size, modification time, inode) are unchanged, so installing, repairing or
/// replacing assets invalidates it without hashing 100 MB on every dictation.
/// The full SHA-256 validation still runs once for each load.
public struct OptionalAssetIdentity: Equatable, Sendable {
    public struct Stamp: Equatable, Sendable {
        let path: String
        let size: Int?
        let modified: Date?
        let inode: UInt64?
    }
    public let modelsDirectory: String
    public let manifestDigest: String
    public let stamps: [Stamp]

    public static func current(manifestData: Data, manifest: ModelManifest, modelsDirectory: URL, assetID: String) -> Self {
        let root = modelsDirectory.standardizedFileURL
        let files = manifest.assets.filter { $0.id == assetID }.flatMap { asset in
            asset.requiredFiles.map { root.appending(path: asset.relativePath, directoryHint: .isDirectory).appending(path: $0.relativePath) }
        }
        let stamps = files.map { url -> Stamp in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return Stamp(path: url.path, size: (attributes?[.size] as? NSNumber)?.intValue,
                         modified: attributes?[.modificationDate] as? Date,
                         inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
        let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        return .init(modelsDirectory: root.path, manifestDigest: digest, stamps: stamps)
    }
}

public enum RetainedAssetSource: String, Sendable {
    case retained
    /// First load in this process, or the first after `release()`.
    case loaded
    /// The models folder, manifest or a declared file changed underneath a retained value.
    case reloadedAfterChange = "reloaded_after_change"
    /// A previous attempt for an older identity failed; this one succeeded.
    case recovered
}

/// Retains one loaded value for one identity. Failures are remembered only for
/// the identity that produced them: any change to the folder, manifest or files
/// (a repair or installation) retries, while an unchanged broken install does
/// not repeat the full hash on every request.
public actor RetainedAssetCache<Value: Sendable> {
    private var entry: (identity: OptionalAssetIdentity, value: Value)?
    private var failure: (identity: OptionalAssetIdentity, error: any Error)?
    public private(set) var loadCount = 0

    public init() {}

    public func value(for identity: OptionalAssetIdentity, load: @Sendable () async throws -> Value) async throws -> (Value, RetainedAssetSource) {
        if let entry, entry.identity == identity { return (entry.value, .retained) }
        if let failure, failure.identity == identity { throw failure.error }
        let source: RetainedAssetSource = entry != nil ? .reloadedAfterChange : failure != nil ? .recovered : .loaded
        entry = nil
        loadCount += 1
        do {
            let value = try await load()
            entry = (identity, value)
            failure = nil
            return (value, source)
        } catch {
            failure = (identity, error)
            throw error
        }
    }

    public var isResident: Bool { entry != nil }

    public func release() {
        entry = nil
        failure = nil
    }
}

/// The optional CTC vocabulary booster, retained for the lifetime of the
/// dictation worker. Models and tokenizer are bound to the asset identity;
/// encoded terms, context and rescorer are bound to the exact usable terms and
/// aliases of a snapshot, so every edit is honored on the next request.
public actor VocabularyBooster {
    public static let assetID = "parakeet-ctc-110m"

    public enum Readiness: String, Sendable {
        /// The snapshot has no usable term; CTC was not touched.
        case notNeeded = "not_needed"
        case ready
        /// Missing or corrupt optional assets. Transcription continues unboosted.
        case unavailable
    }

    struct Resources: Sendable {
        let models: CtcModels
        let tokenizer: CtcTokenizer
        let directory: URL
    }

    struct Prepared: Sendable {
        let terms: [WorkerVocabularySnapshot.Term]
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }

    public struct Report: Sendable {
        public var readiness: Readiness
        public var source: RetainedAssetSource?
        public var preparationSeconds: Double = 0
        public var modelLoadSeconds: Double = 0
        public var contextReused = false
        public var warmInferenceSeconds: Double?
    }

    private let cache = RetainedAssetCache<Resources>()
    private var prepared: Prepared?
    private var inferenceWarmed = false

    public init() {}

    public var modelLoadCount: Int { get async { await cache.loadCount } }
    public var isResident: Bool { get async { await cache.isResident } }

    /// Releases models, tokenizer and context with the worker's own unload.
    public func release() async {
        await cache.release()
        prepared = nil
        inferenceWarmed = false
    }

    /// Public entry for the worker's warm operation.
    public func warm(snapshot: WorkerVocabularySnapshot, manifestURL: URL, modelsDirectory: URL) async -> Report {
        await prepare(snapshot: snapshot, manifestURL: manifestURL, modelsDirectory: modelsDirectory, warmInference: true).1
    }

    /// Loads (or reuses) the booster for `snapshot`. With `warmInference`, a
    /// short representative prediction runs once per loaded model so the first
    /// real dictation does not pay Core ML's first-prediction cost.
    func prepare(snapshot: WorkerVocabularySnapshot, manifestURL: URL, modelsDirectory: URL, warmInference: Bool) async -> (Prepared?, Report) {
        guard !snapshot.usableTerms.isEmpty else { return (nil, .init(readiness: .notNeeded)) }
        // The manifest is a few kilobytes; reading it on each request is what
        // lets a model installation be noticed without hashing the weights.
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: manifestData) else {
            await release()
            return (nil, .init(readiness: .unavailable))
        }
        return await prepare(snapshot: snapshot, manifest: manifest, manifestData: manifestData,
                             modelsDirectory: modelsDirectory, warmInference: warmInference)
    }

    func prepare(snapshot: WorkerVocabularySnapshot, manifest: ModelManifest, manifestData: Data, modelsDirectory: URL,
                 warmInference: Bool) async -> (Prepared?, Report) {
        let terms = snapshot.usableTerms
        guard !terms.isEmpty else { return (nil, .init(readiness: .notNeeded)) }
        let started = ContinuousClock.now
        var report = Report(readiness: .unavailable)
        do {
            let identity = OptionalAssetIdentity.current(manifestData: manifestData, manifest: manifest,
                                                         modelsDirectory: modelsDirectory, assetID: Self.assetID)
            let loadStarted = ContinuousClock.now
            let (resources, source) = try await cache.value(for: identity) {
                let models = try await OfflineModelLoader.loadCTC(manifest: manifest, modelsDirectory: modelsDirectory)
                let directory = modelsDirectory.appendingPathComponent("parakeet-ctc-110m-coreml")
                return Resources(models: models, tokenizer: try await CtcTokenizer.load(from: directory), directory: directory)
            }
            report.modelLoadSeconds = (ContinuousClock.now - loadStarted).seconds
            report.source = source
            if source != .retained {
                prepared = nil
                inferenceWarmed = false
            }
            let current: Prepared
            if let prepared, prepared.terms == terms {
                current = prepared
                report.contextReused = true
            } else {
                let encoded = terms.compactMap { term -> CustomVocabularyTerm? in
                    let ids = resources.tokenizer.encode(term.text)
                    guard !ids.isEmpty else { return nil }
                    return CustomVocabularyTerm(text: term.text, aliases: term.aliases.filter { $0.count >= 3 }, ctcTokenIds: ids)
                }
                guard !encoded.isEmpty else {
                    report.readiness = .notNeeded
                    report.preparationSeconds = (ContinuousClock.now - started).seconds
                    return (nil, report)
                }
                let context = CustomVocabularyContext(terms: encoded)
                let spotter = CtcKeywordSpotter(models: resources.models)
                let rescorer = try await VocabularyRescorer.create(
                    spotter: spotter, vocabulary: context,
                    config: .init(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false),
                    ctcModelDirectory: resources.directory
                )
                current = Prepared(terms: terms, context: context, spotter: spotter, rescorer: rescorer)
                prepared = current
            }
            if warmInference, !inferenceWarmed {
                let inferenceStarted = ContinuousClock.now
                // Two seconds of silence exercise the same encoder program as speech.
                _ = try await current.spotter.spotKeywordsWithLogProbs(
                    audioSamples: [Float](repeating: 0, count: 32_000), customVocabulary: current.context)
                report.warmInferenceSeconds = (ContinuousClock.now - inferenceStarted).seconds
            }
            // A real dictation's spotting pass warms the model just as well.
            inferenceWarmed = true
            report.readiness = .ready
            report.preparationSeconds = (ContinuousClock.now - started).seconds
            return (current, report)
        } catch {
            prepared = nil
            inferenceWarmed = false
            report.readiness = .unavailable
            report.preparationSeconds = (ContinuousClock.now - started).seconds
            return (nil, report)
        }
    }
}

public extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
