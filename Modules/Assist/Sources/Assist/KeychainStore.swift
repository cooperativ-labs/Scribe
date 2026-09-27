import Foundation
import Security

/// Where secrets live. The Keychain in the app; memory in tests.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
    /// Whether an item exists, without reading its secret (which, for the
    /// Keychain, can ask the person for permission).
    func contains(_ account: String) throws -> Bool
}

extension SecretStore {
    public func contains(_ account: String) throws -> Bool {
        try read(account) != nil
    }
}

/// Generic-password items under one service. Tokens and API keys are kept
/// here and nowhere else: never in UserDefaults, and never in `~/.codex`,
/// which belongs to Codex.
public struct KeychainStore: SecretStore {
    /// The ChatGPT sign-in's tokens.
    public static let chatGPTService = "co.cooperativ.scribe.chatgpt"
    /// The OpenAI API key.
    public static let openAIService = "co.cooperativ.scribe.openai"

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func contains(_ account: String) throws -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError(status: status)
        }
    }

    public func write(_ data: Data, for account: String) throws {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, update)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery(account)
            item[kSecValueData as String] = data
            // Readable only while this Mac is unlocked, and never synced or migrated.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "The Keychain refused the request: \(message)"
    }
}

/// A store that forgets everything with the process, for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func write(_ data: Data, for account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func delete(_ account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: account) }
    }
}
