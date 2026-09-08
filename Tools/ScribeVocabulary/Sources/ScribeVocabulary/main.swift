import Darwin
import Foundation
import ScribeVocabularyCLI

/// The command-line face of the vocabulary, so an agent can maintain the same
/// list a person edits in Settings without going through the app.
@main
struct ScribeVocabulary {
    static func main() {
        do {
            let output = try VocabularyCommand().run(Array(CommandLine.arguments.dropFirst()))
            write(output.standardError, to: .standardError)
            write(output.standardOutput, to: .standardOutput)
        } catch let error as CLIError {
            write("scribe-vocab: \(error.message)\n", to: .standardError)
            // A usage mistake gets the usage; a missing term does not, because
            // the caller already knows how to spell the command.
            if case .usage = error { write("\n\(ScribeVocabularyUsage.text)\n", to: .standardError) }
            exit(error.exitCode)
        } catch {
            write("scribe-vocab: \(error.localizedDescription)\n", to: .standardError)
            exit(1)
        }
    }

    private static func write(_ text: String, to handle: FileHandle) {
        guard !text.isEmpty else { return }
        handle.write(Data(text.utf8))
    }
}
