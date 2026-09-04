@preconcurrency import AVFoundation
import Foundation
import Speakers
import TranscriptionWorkerSupport

/// Generates disjoint local-voice sessions, extracts pinned WeSpeaker embeddings
/// through `EnrollmentEmbeddingExtractor`, and sweeps matcher thresholds.
@main
struct SpeakerEnrollmentCalibration {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let report = try await run(options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(report))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if let markdownURL = options.markdownURL {
                try report.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
            }
        } catch {
            FileHandle.standardError.write(Data("SpeakerEnrollmentCalibration failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run(options: Options) async throws -> CalibrationOutput {
        let workspace = FileManager.default.temporaryDirectory.appending(
            path: "speaker-enrollment-cal-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let manifest = try ModelManifest.load(from: options.manifestURL)
        let extractor = EnrollmentEmbeddingExtractor(manifest: manifest, modelsDirectory: options.modelsURL)
        let workerExtractor = WorkerBackedSpeakerExtractor(inner: extractor)
        let people = try labeledPeople()
        let pipeline = SpeakerEnrollmentPipeline()
        let store = try SpeakerProfileStore(directoryURL: workspace.appending(path: "library", directoryHint: .isDirectory))

        var enrollment: [LabeledSpeakerEmbedding] = []
        var evaluation: [LabeledSpeakerEmbedding] = []

        for person in people where person.enrolled {
            var enrollExcerpts: [SpeakerEnrollmentExcerpt] = []
            for (index, text) in person.enrollmentTexts.enumerated() {
                let file = try synthesize(
                    voice: person.voice,
                    text: text,
                    sampleRate: 16_000,
                    directory: workspace,
                    name: "\(person.id)-enroll-\(index)"
                )
                let duration = try audioDuration(file)
                enrollExcerpts.append(
                    SpeakerEnrollmentExcerpt(
                        excerptID: "\(person.id)-enroll-\(index)",
                        timeRanges: [SpeakerTimeRange(startMs: 0, endMs: Int((duration * 1000).rounded()))],
                        isConfirmed: true
                    )
                )
            }
            let enrolled = try await pipeline.enroll(
                request: .selectedAudioFile(
                    sourceID: "cal:\(person.id)",
                    audioFileURL: workspace.appending(path: "\(person.id)-enroll-0.wav"),
                    target: .existingProfile(try await ensureProfile(person, store: store)),
                    excerpts: enrollExcerpts,
                    confirmation: .userConfirmedExcerpts
                ),
                into: store,
                using: PerFileExtractor(inner: workerExtractor, files: enrollFileMap(person: person, directory: workspace))
            )
            for (index, signature) in enrolled.profile.signatures.enumerated() {
                enrollment.append(
                    LabeledSpeakerEmbedding(
                        sampleID: "\(person.id)-enroll-\(index)",
                        sessionID: "enroll-\(person.id)",
                        clusterID: "enroll-\(person.id)",
                        profileID: person.profileID,
                        vector: signature.embeddingVector,
                        format: SpeakerEmbeddingFormat(
                            model: signature.embeddingModel,
                            preprocessingVersion: signature.preprocessingVersion,
                            normalizationVersion: signature.normalizationVersion,
                            transformVersion: signature.transformVersion
                        )
                    )
                )
            }
        }

        for person in people {
            for (index, text) in person.evaluationTexts.enumerated() {
                let rate: Int = person.deviceShift && index == 0 ? 44_100 : 16_000
                let file = try synthesize(
                    voice: person.voice,
                    text: text,
                    sampleRate: rate,
                    directory: workspace,
                    name: "\(person.id)-eval-\(index)"
                )
                let duration = try audioDuration(file)
                let extracted = try await workerExtractor.extract(
                    SpeakerEmbeddingExtractionRequest(
                        excerptID: "\(person.id)-eval-\(index)",
                        audioFileURL: file,
                        ranges: [SpeakerTimeRange(startMs: 0, endMs: Int((duration * 1000).rounded()))]
                    )
                )
                let embedding = try requireSingle(extracted, excerptID: "\(person.id)-eval-\(index)")
                evaluation.append(
                    LabeledSpeakerEmbedding(
                        sampleID: "\(person.id)-eval-\(index)",
                        sessionID: "eval-\(person.id)",
                        clusterID: "eval-\(person.id)",
                        profileID: person.enrolled ? person.profileID : nil,
                        vector: embedding.vector,
                        format: embedding.format
                    )
                )
            }
        }

        let brief = people.first { $0.id == "jake" }!
        let briefFile = try synthesize(
            voice: brief.voice,
            text: "Yes, agreed.",
            sampleRate: 16_000,
            directory: workspace,
            name: "jake-brief"
        )
        let briefDuration = try audioDuration(briefFile)
        let briefEmbedding = try requireSingle(
            try await workerExtractor.extract(
                SpeakerEmbeddingExtractionRequest(
                    excerptID: "jake-brief",
                    audioFileURL: briefFile,
                    ranges: [SpeakerTimeRange(startMs: 0, endMs: Int((briefDuration * 1000).rounded()))]
                )
            ),
            excerptID: "jake-brief"
        )
        evaluation.append(
            LabeledSpeakerEmbedding(
                sampleID: "jake-brief",
                sessionID: "eval-jake-brief",
                clusterID: "eval-jake-brief",
                profileID: brief.profileID,
                vector: briefEmbedding.vector,
                format: briefEmbedding.format
            )
        )

        let harness = SpeakerIdentityCalibrationHarness()
        let thresholds = sweepThresholds()
        let report = try harness.run(enrollment: enrollment, evaluation: evaluation, thresholds: thresholds)
        let point = harness.chooseOperatingPoint(from: report, maximumWrongNameRate: 0.01)
        let signatures = try await store.profiles().map { profile in
            ProfileSummary(displayName: profile.displayName, signatureCount: profile.signatures.count)
        }
        return CalibrationOutput(
            corpus: "macOS local voices; 16 kHz enrollment and mixed 16 kHz/44.1 kHz evaluation; not consented human speech",
            pinnedFormat: FormatSummary(format: SpeakerPinnedEmbeddingFormat.current),
            enrollmentSampleCount: report.enrollmentSampleCount,
            evaluationSampleCount: report.evaluationSampleCount,
            evaluationClusterCount: report.evaluationClusterCount,
            enrolledProfiles: signatures,
            operatingPoint: point.map(OperatingPointSummary.init),
            sweeps: report.sweeps.map(SweepSummary.init),
            markdown: markdown(report: report, point: point, signatures: signatures)
        )
    }

    private static func ensureProfile(_ person: Person, store: SpeakerProfileStore) async throws -> UUID {
        if let existing = try await store.profile(id: person.profileID) {
            return existing.profileID
        }
        let created = try await store.createProfile(
            SpeakerProfileDraft(displayName: person.displayName, profileID: person.profileID)
        )
        return created.profileID
    }

    private static func enrollFileMap(person: Person, directory: URL) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: person.enrollmentTexts.indices.map { index in
            ("\(person.id)-enroll-\(index)", directory.appending(path: "\(person.id)-enroll-\(index).wav"))
        })
    }

    private static func requireSingle(
        _ embeddings: [ExtractedSpeakerEmbedding],
        excerptID: String
    ) throws -> ExtractedSpeakerEmbedding {
        guard embeddings.count == 1, let embedding = embeddings.first else {
            throw CalibrationError.unexpectedEmbeddingCount(excerptID, embeddings.count)
        }
        guard embedding.format == SpeakerPinnedEmbeddingFormat.current else {
            throw CalibrationError.incompatibleFormat(excerptID)
        }
        return embedding
    }

    private static func labeledPeople() throws -> [Person] {
        let jake = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let sarah = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let daniel = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        return [
            Person(
                id: "jake",
                displayName: "Jake",
                profileID: jake,
                voice: "Samantha (English (US))",
                enrolled: true,
                deviceShift: true,
                enrollmentTexts: [paragraphA, paragraphB, paragraphC],
                evaluationTexts: [paragraphD, paragraphE]
            ),
            Person(
                id: "sarah",
                displayName: "Sarah",
                profileID: sarah,
                voice: "Shelley (English (US))",
                enrolled: true,
                deviceShift: true,
                enrollmentTexts: [paragraphA, paragraphB, paragraphC],
                evaluationTexts: [paragraphD, paragraphE]
            ),
            Person(
                id: "daniel",
                displayName: "Daniel",
                profileID: daniel,
                voice: "Daniel (English (UK))",
                enrolled: true,
                deviceShift: false,
                enrollmentTexts: [paragraphA, paragraphB, paragraphC],
                evaluationTexts: [paragraphD, paragraphE]
            ),
            Person(
                id: "unknown",
                displayName: "Unknown",
                profileID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                voice: "Albert",
                enrolled: false,
                deviceShift: false,
                enrollmentTexts: [],
                evaluationTexts: [paragraphD, paragraphE]
            ),
        ]
    }

    private static func sweepThresholds() -> [SpeakerCalibrationThreshold] {
        [0.70, 0.75, 0.80, 0.85, 0.88, 0.90, 0.92, 0.95].flatMap { automatic in
            [0.03, 0.05, 0.08].flatMap { margin in
                [1, 2].map { excerpts in
                    SpeakerCalibrationThreshold(
                        automaticThreshold: Float(automatic),
                        suggestionThreshold: Float(max(0.55, automatic - 0.15)),
                        minimumMargin: Float(margin),
                        minimumConsistentExcerpts: excerpts
                    )
                }
            }
        }
    }

    private static func synthesize(
        voice: String,
        text: String,
        sampleRate: Int,
        directory: URL,
        name: String
    ) throws -> URL {
        let aiff = directory.appending(path: "\(name).aiff")
        let wav = directory.appending(path: "\(name).wav")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@\(sampleRate)", aiff.path, wav.path])
        return wav
    }

    private static func audioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func run(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw CalibrationError.commandFailed(launchPath, message)
        }
    }

    private static func markdown(
        report: SpeakerCalibrationReport,
        point: SpeakerCalibrationOperatingPoint?,
        signatures: [ProfileSummary]
    ) -> String {
        var lines: [String] = [
            "# Speaker identity calibration",
            "",
            "Local-synthesis stand-in run using the worker's pinned WeSpeaker export (`wespeaker-embedding-coreml`, revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594`, preprocessing `fluidaudio-offline-fbank-16khz-mono-v0.12.4`, normalization `l2-unit-v1`, transform `identity-v1`). Enrollment used confirmed 16 kHz excerpts totaling about 20–60 seconds per person. Evaluation used disjoint sessions, a 44.1 kHz device-shift condition, similar US-English voices (Samantha vs Shelley), a UK-English enrolled voice, an unknown voice (Albert), and a brief utterance.",
            "",
            "This is **not** the consented human evaluation set required by the 1% wrong-name release gate. It measures whether the worker-exported representation plus the matcher can be calibrated at all.",
            "",
            "- Enrollment embeddings: \(report.enrollmentSampleCount)",
            "- Evaluation embeddings: \(report.evaluationSampleCount)",
            "- Evaluation clusters: \(report.evaluationClusterCount)",
            "- Enrolled profiles: \(signatures.map { "\($0.displayName) (\($0.signatureCount) signatures)" }.joined(separator: ", "))",
            "",
        ]
        if let point {
            let precision = point.sweep.precision.map { String(format: "%.3f", $0) } ?? "n/a"
            let wrong = point.wrongNameRate.map { String(format: "%.3f", $0) } ?? "n/a"
            lines.append(contentsOf: [
                "## Operating point",
                "",
                "- Automatic threshold: \(point.threshold.automaticThreshold)",
                "- Suggestion threshold: \(point.threshold.suggestionThreshold)",
                "- Minimum margin: \(point.threshold.minimumMargin)",
                "- Minimum consistent excerpts: \(point.threshold.minimumConsistentExcerpts)",
                "- Precision: \(precision)",
                "- Wrong-name rate: \(wrong) (budget \(point.maximumWrongNameRate))",
                "- Coverage: \(String(format: "%.3f", point.sweep.coverage))",
                "- Unknown false accepts: \(point.sweep.unknownSpeakerFalseAcceptCount) / \(point.sweep.unknownSpeakerSampleCount)",
                "- Meets 1% wrong-name target on this corpus: \(point.meetsWrongNameTarget ? "yes" : "no")",
                "",
            ])
            if !point.meetsWrongNameTarget {
                lines.append(contentsOf: [
                    "## Shortfall",
                    "",
                    "The 1% wrong-name target was not met on this stand-in corpus. Recommended next step: collect consented disjoint recordings of real people across devices, including similar voices and brief speech, extract embeddings with `EnrollmentEmbeddingExtractor`, and re-run `SpeakerEnrollmentCalibration` before locking matcher defaults.",
                    "",
                ])
            } else if point.sweep.coverage < 0.5 {
                lines.append(contentsOf: [
                    "## Coverage shortfall",
                    "",
                    "Wrong-name rate met the 1% budget, but automatic coverage was only \(String(format: "%.0f", point.sweep.coverage * 100))%. A matcher that names one cluster and abstains on the rest does not satisfy the feature. Production defaults stay at 0.85 / two consistent excerpts until consented human recordings exist. Recommended next step: collect disjoint consented sessions with different devices, similar voices, unknown people, and brief speech, then re-run `SpeakerEnrollmentCalibration`.",
                    "",
                ])
            }
        } else {
            lines.append(contentsOf: [
                "## Shortfall",
                "",
                "Every sweep abstained. Recommended next step: inspect worker embeddings on consented speech; a matcher that never names anyone does not satisfy the feature.",
                "",
            ])
        }
        lines.append(contentsOf: [
            "## Sweeps",
            "",
            "| auto | margin | excerpts | automatic | precision | coverage | unknown FA |",
            "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ])
        for sweep in report.sweeps {
            let precision = sweep.precision.map { String(format: "%.3f", $0) } ?? "—"
            lines.append(
                "| \(sweep.threshold.automaticThreshold) | \(sweep.threshold.minimumMargin) | \(sweep.threshold.minimumConsistentExcerpts) | \(sweep.automaticAssignmentCount) | \(precision) | \(String(format: "%.3f", sweep.coverage)) | \(sweep.unknownSpeakerFalseAcceptCount) |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private let paragraphA = "The weekly planning review covers launch risks, timeline changes, remaining design questions, and how we will sequence recording and transcription work. Please keep the original file and preserve source-relative timestamps without rewriting speech. If speakers overlap, mark uncertainty instead of inventing missing words."
private let paragraphB = "We still need a persistent speaker library, verified enrollment samples, and a matcher that can leave an unknown person unnamed. Do not silently train a profile from an automatic label. Store several confirmed examples from more than one microphone when they are available."
private let paragraphC = "For long recordings, keep global speaker clustering across the file and restore absolute offsets after chunked recognition. Export names from the saved transcript revision so text, JSON, and subtitles agree. Existing exported files must not change in the background."
private let paragraphD = "On a later call from a different room, the same people discussed packaging, notarization, offline model bundle size, and whether capture stays prioritized while transcription is queued. They also mentioned similar voices and a guest who should remain unnamed."
private let paragraphE = "Please confirm the brief acknowledgements, the unknown attendee, and that enrollment used disjoint sessions rather than the same take twice. The matcher should abstain when speech is too short or the score margin is weak."

private struct Person {
    let id: String
    let displayName: String
    let profileID: UUID
    let voice: String
    let enrolled: Bool
    let deviceShift: Bool
    let enrollmentTexts: [String]
    let evaluationTexts: [String]
}

private struct WorkerBackedSpeakerExtractor: SpeakerEmbeddingExtracting {
    let inner: EnrollmentEmbeddingExtractor

    func extract(_ request: SpeakerEmbeddingExtractionRequest) async throws -> [ExtractedSpeakerEmbedding] {
        let ranges = request.ranges.map {
            AudioTimeRange(startSeconds: Double($0.startMs) / 1000, endSeconds: Double($0.endMs) / 1000)
        }
        let embedding = try await inner.extract(from: request.audioFileURL, ranges: ranges)
        return [
            ExtractedSpeakerEmbedding(
                vector: embedding.vector,
                format: SpeakerEmbeddingFormat(
                    model: SpeakerEmbeddingModelIdentity(modelID: embedding.modelID, revision: embedding.modelRevision),
                    preprocessingVersion: embedding.preprocessingVersion,
                    normalizationVersion: embedding.normalizationVersion,
                    transformVersion: SpeakerPinnedEmbeddingFormat.transformVersion
                ),
                usableSpeechDuration: ranges.reduce(0) { $0 + $1.duration }
            )
        ]
    }
}

/// Routes each excerpt to the wav synthesized for that excerpt ID.
private struct PerFileExtractor: SpeakerEmbeddingExtracting {
    let inner: WorkerBackedSpeakerExtractor
    let files: [String: URL]

    func extract(_ request: SpeakerEmbeddingExtractionRequest) async throws -> [ExtractedSpeakerEmbedding] {
        guard let url = files[request.excerptID] else {
            return try await inner.extract(request)
        }
        return try await inner.extract(
            SpeakerEmbeddingExtractionRequest(
                excerptID: request.excerptID,
                audioFileURL: url,
                ranges: request.ranges
            )
        )
    }
}

private enum CalibrationError: Error, LocalizedError {
    case commandFailed(String, String)
    case unexpectedEmbeddingCount(String, Int)
    case incompatibleFormat(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, message):
            "\(command) failed: \(message)"
        case let .unexpectedEmbeddingCount(id, count):
            "Expected one embedding for \(id), got \(count)."
        case let .incompatibleFormat(id):
            "Embedding for \(id) did not match the pinned WeSpeaker format."
        }
    }
}

private struct Options {
    let manifestURL: URL
    let modelsURL: URL
    let markdownURL: URL?

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.count else { throw OptionsError.usage }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard let manifest = values["--manifest"], let models = values["--models"] else { throw OptionsError.usage }
        manifestURL = URL(fileURLWithPath: manifest)
        modelsURL = URL(fileURLWithPath: models, isDirectory: true)
        markdownURL = values["--markdown"].map { URL(fileURLWithPath: $0) }
    }
}

private enum OptionsError: LocalizedError {
    case usage
    var errorDescription: String? {
        "Usage: SpeakerEnrollmentCalibration --manifest <model_manifest.json> --models <models-dir> [--markdown <report.md>]"
    }
}

private struct CalibrationOutput: Codable {
    let corpus: String
    let pinnedFormat: FormatSummary
    let enrollmentSampleCount: Int
    let evaluationSampleCount: Int
    let evaluationClusterCount: Int
    let enrolledProfiles: [ProfileSummary]
    let operatingPoint: OperatingPointSummary?
    let sweeps: [SweepSummary]
    let markdown: String
}

private struct FormatSummary: Codable {
    let modelID: String
    let modelRevision: String
    let preprocessingVersion: String
    let normalizationVersion: String
    let transformVersion: String

    init(format: SpeakerEmbeddingFormat) {
        modelID = format.model.modelID
        modelRevision = format.model.revision
        preprocessingVersion = format.preprocessingVersion
        normalizationVersion = format.normalizationVersion
        transformVersion = format.transformVersion
    }
}

private struct ProfileSummary: Codable {
    let displayName: String
    let signatureCount: Int
}

private struct OperatingPointSummary: Codable {
    let automaticThreshold: Float
    let suggestionThreshold: Float
    let minimumMargin: Float
    let minimumConsistentExcerpts: Int
    let precision: Double?
    let coverage: Double
    let wrongNameRate: Double?
    let unknownSpeakerFalseAcceptCount: Int
    let meetsWrongNameTarget: Bool

    init(_ point: SpeakerCalibrationOperatingPoint) {
        automaticThreshold = point.threshold.automaticThreshold
        suggestionThreshold = point.threshold.suggestionThreshold
        minimumMargin = point.threshold.minimumMargin
        minimumConsistentExcerpts = point.threshold.minimumConsistentExcerpts
        precision = point.sweep.precision
        coverage = point.sweep.coverage
        wrongNameRate = point.wrongNameRate
        unknownSpeakerFalseAcceptCount = point.sweep.unknownSpeakerFalseAcceptCount
        meetsWrongNameTarget = point.meetsWrongNameTarget
    }
}

private struct SweepSummary: Codable {
    let automaticThreshold: Float
    let minimumMargin: Float
    let automaticAssignmentCount: Int
    let precision: Double?
    let coverage: Double
    let unknownSpeakerFalseAcceptCount: Int

    init(_ sweep: SpeakerCalibrationSweepResult) {
        automaticThreshold = sweep.threshold.automaticThreshold
        minimumMargin = sweep.threshold.minimumMargin
        automaticAssignmentCount = sweep.automaticAssignmentCount
        precision = sweep.precision
        coverage = sweep.coverage
        unknownSpeakerFalseAcceptCount = sweep.unknownSpeakerFalseAcceptCount
    }
}
