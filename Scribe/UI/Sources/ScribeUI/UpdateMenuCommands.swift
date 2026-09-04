import Foundation

/// The update state and actions the menu needs from its host application.
/// Scribe presents the GitHub release for download; it never modifies its own
/// bundle while running.
public enum UpdateMenuState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case failed(message: String)
}

public struct UpdateMenuCommands {
    public let state: UpdateMenuState
    private let checkForUpdatesAction: () -> Void
    private let downloadUpdateAction: () -> Void

    public init(
        state: UpdateMenuState,
        checkForUpdates: @escaping () -> Void,
        downloadUpdate: @escaping () -> Void
    ) {
        self.state = state
        checkForUpdatesAction = checkForUpdates
        downloadUpdateAction = downloadUpdate
    }

    public func checkForUpdates() { checkForUpdatesAction() }
    public func downloadUpdate() { downloadUpdateAction() }
}
