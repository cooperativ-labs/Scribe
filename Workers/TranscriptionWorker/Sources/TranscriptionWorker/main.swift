import Foundation
import TranscriptionWorkerSupport

@main
struct TranscriptionWorker {
    static func main() {
        do {
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            WorkerRequestLoop(configuration: .init(manifestURL: configuration.manifestURL, modelsDirectory: configuration.modelsDirectory)).run()
        } catch {
            FileHandle.standardError.write(Data("TranscriptionWorker setup failed: \(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }
}

private struct Configuration {
    let manifestURL: URL
    let modelsDirectory: URL

    init(arguments: [String]) throws {
        var manifest: String?
        var models: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--manifest", "--models-directory":
                guard index + 1 < arguments.count else { throw ConfigurationError.missingValue(arguments[index]) }
                if arguments[index] == "--manifest" { manifest = arguments[index + 1] }
                else { models = arguments[index + 1] }
                index += 2
            default: throw ConfigurationError.unrecognizedArgument(arguments[index])
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        manifestURL = URL(fileURLWithPath: manifest ?? ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTION_MODEL_MANIFEST"] ?? cwd.appending(path: "model_manifest.json").path)
        modelsDirectory = URL(fileURLWithPath: models ?? ProcessInfo.processInfo.environment["SCRIBE_TRANSCRIPTION_MODELS_DIRECTORY"] ?? cwd.appending(path: "models").path, isDirectory: true)
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
