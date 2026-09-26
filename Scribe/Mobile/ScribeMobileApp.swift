import SwiftUI

@main
struct ScribeMobileApp: App {
    @State private var model: MobileAppModel?
    @State private var startupError: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let model { MobileRootView(model: model) }
                else if let startupError { ContentUnavailableView("Scribe could not open", systemImage: "exclamationmark.triangle", description: Text(startupError)) }
                else { ProgressView("Opening Scribe…") }
            }
            .task {
                guard model == nil else { return }
                do { model = try MobileAppModel() } catch { startupError = error.localizedDescription }
            }
        }
    }
}
