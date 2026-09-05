import Foundation

/// The update state and actions the menu needs from its host application.
/// Installation is an explicit restart after the download has been verified.
public enum UpdateMenuState: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String)
    case downloading
    case readyToInstall(version: String)
    case installing
    case failed(message: String)
}

public struct UpdateMenuCommands {
    public let state: UpdateMenuState
    private let checkForUpdatesAction: () -> Void
    private let downloadUpdateAction: () -> Void
    private let installUpdateAction: () -> Void

    public init(
        state: UpdateMenuState,
        checkForUpdates: @escaping () -> Void,
        downloadUpdate: @escaping () -> Void,
        installUpdate: @escaping () -> Void
    ) {
        self.state = state
        checkForUpdatesAction = checkForUpdates
        downloadUpdateAction = downloadUpdate
        installUpdateAction = installUpdate
    }

    public func checkForUpdates() { checkForUpdatesAction() }
    public func installUpdate() { installUpdateAction() }
    public func downloadUpdate() { downloadUpdateAction() }
}
