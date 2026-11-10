import Foundation

/// The update state and actions the menu needs from its host application.
/// A newer release is downloaded and verified as soon as a check finds it,
/// so there is no "available, not yet downloaded" state and no manual
/// download action. Installation is an explicit restart after verification.
public enum UpdateMenuState: Equatable {
    case idle
    case checking
    case upToDate
    case downloading(version: String)
    case readyToInstall(version: String)
    case installing
    case failed(message: String)
}

public struct UpdateMenuCommands {
    public let state: UpdateMenuState
    private let checkForUpdatesAction: () -> Void
    private let installUpdateAction: () -> Void

    public init(
        state: UpdateMenuState,
        checkForUpdates: @escaping () -> Void,
        installUpdate: @escaping () -> Void
    ) {
        self.state = state
        checkForUpdatesAction = checkForUpdates
        installUpdateAction = installUpdate
    }

    public func checkForUpdates() { checkForUpdatesAction() }
    public func installUpdate() { installUpdateAction() }
}
