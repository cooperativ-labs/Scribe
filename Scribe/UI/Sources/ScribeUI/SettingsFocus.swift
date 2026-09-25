import Combine
import Foundation

/// A place in Settings something outside Settings can ask for.
public enum SettingsSection: String, Hashable, Sendable {
    case vocabulary
    case dictation
}

/// Carries "open Settings at the vocabulary" from the transcript window to the
/// settings view.
///
/// The settings window is created once and reused, so the request cannot be an
/// initializer argument: the second time someone presses the button the window
/// already exists. It is a published request instead, and the section it names
/// is scrolled to and marked until the person has had a moment to see it.
@MainActor
public final class SettingsFocusModel: ObservableObject {
    /// The section to scroll to, cleared once the highlight has been shown.
    @Published public private(set) var section: SettingsSection?
    /// Bumped on every request so pressing the button twice highlights twice.
    @Published public private(set) var requestCount = 0

    public init() {}

    public func request(_ section: SettingsSection) {
        self.section = section
        requestCount += 1
    }

    public func clear() {
        section = nil
    }
}
