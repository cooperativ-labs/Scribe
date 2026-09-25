import Foundation
import TranscriptionWorkerSupport

@main
struct TranscriptionWorker {
    static func main() {
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            WorkerRequestLoop(configuration: .init(manifestURL: configuration.manifestURL, modelsDirectory: configuration.modelsDirectory), mode: configuration.mode).run()
        } catch {
            FileHandle.standardError.write(Data("TranscriptionWorker setup failed: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }
}

private struct Configuration {
    let manifestURL: URL
    let modelsDirectory: URL
    let mode: WorkerRequestLoop.Mode

    init(arguments: [String]) throws {
        var manifest: String?
        var models: String?
        var mode: WorkerRequestLoop.Mode = .batch
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest", "--models-directory", "--mode":
                guard index + 1 < arguments.count else { throw ConfigurationError.missingValue(arguments[index]) }
                if arguments[index] == "--manifest" { manifest = arguments[index + 1] }
                else if arguments[index] == "--models-directory" { models = arguments[index + 1] }
                else {
                    guard let parsed = WorkerRequestLoop.Mode(rawValue: arguments[index + 1]) else {
                        throw ConfigurationError.unrecognizedArgument(arguments[index + 1])
                    }
                    mode = parsed
                }
                index += 2
            default: throw ConfigurationError.unrecognizedArgument(arguments[index])
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        manifestURL = URL(fileURLWithPath: manifest ?? ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTION_MODEL_MANIFEST"] ?? cwd.appending(path: "model_manifest.json").path)
        modelsDirectory = URL(fileURLWithPath: models ?? ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTION_MODELS_DIRECTORY"] ?? cwd.appending(path: "models").path, isDirectory: true)
        self.mode = mode
    }
}

private enum ConfigurationError: LocalizedError {
    case missingValue(String)
    case unrecognizedArgument(String)

    var errorDescription: String? {
        switch self {
        case let .missingValue(argument): "Missing value for \(argument)."
        case let .unrecognizedArgument(argument): "Unrecognized argument \(argument)."
        }
    }
}
