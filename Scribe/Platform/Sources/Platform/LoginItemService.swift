import Foundation
import ServiceManagement

/// The subset of `SMAppService` that the settings model needs.
///
/// Keeping the system service behind this protocol lets settings behavior be
/// tested without changing the user's real Login Items configuration.
public protocol LoginItemManaging {
    var status: LoginItemStatus { get }

    func register() throws
    func unregister() throws
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Registers the main application with macOS Login Items.
public final class SystemLoginItemManager: LoginItemManaging {
    private let service: SMAppService

    public init(service: SMAppService = .mainApp) {
        self.service = service
    }

    public var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}
