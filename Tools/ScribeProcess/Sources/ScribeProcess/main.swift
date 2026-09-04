import Darwin
import Foundation
import ScribeProcessSupport

@main
struct ScribeProcess {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1, arguments[0] != "--help", arguments[0] != "-h" else {
            FileHandle.standardError.write(Data("usage: scribe-process <session-directory>\n".utf8))
            exit(arguments.first == "--help" || arguments.first == "-h" ? 0 : 64)
        }
        let directory = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path) else {
            FileHandle.standardError.write(Data("scribe-process: no metadata.json in \(directory.path)\n".utf8))
            exit(66)
        }
        do {
            let result = try ScribeProcessSupport.process(sessionDirectory: directory)
            FileHandle.standardOutput.write(Data("processed \(directory.path): \(result.result.sha256)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("scribe-process: \(error)\n".utf8))
            exit(1)
        }
    }
}
