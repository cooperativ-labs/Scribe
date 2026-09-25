import AppKit
import Dictation
import ScribeUI
import SwiftUI

@main
@MainActor
struct Harness {
    static func main() throws {
        print("Screens: \(NSScreen.screens.count)")
        for screen in NSScreen.screens { print("Frame: \(screen.frame), visible: \(screen.visibleFrame)") }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/scribe-dictation-indicator")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let states: [(String, DictationState, Bool, Bool)] = [
            ("listening-hold", .listening(level: 0.52), false, false),
            ("listening-toggle", .listening(level: 0.68), true, false),
            ("transcribing", .transcribing, false, true),
            ("inserted", .inserted, false, false),
            ("copied", .copied, false, false),
            ("warming", .warming, false, false),
            ("error", .error("Microphone unavailable"), false, false),
        ]
        for (name, state, toggle, label) in states {
            let view = DictationIndicatorView(state: state, showsToggleControls: toggle,
                                              showsTranscribingLabel: label)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Could not render \(name)")
            }
            try png.write(to: output.appending(path: "\(name).png"))
        }
    }
}
