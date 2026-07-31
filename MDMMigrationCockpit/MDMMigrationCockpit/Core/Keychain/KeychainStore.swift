import Foundation
import Security

/// Stores API credentials in the login Keychain.
///
/// Nothing sensitive is written to disk in plaintext, and nothing is held in
/// UserDefaults. Non-secret values (tenant IDs, URLs) live in UserDefaults;
/// only secrets come through here.
enum KeychainStore {

    private static let service = "com.intuneirl.MDMMigrationCockpit"

    enum Account: String, CaseIterable {
        case jamfClientSecret
        case intuneClientSecret   // legacy, no longer written
        case intuneRefreshToken
        case abmPrivateKey

        var displayName: String {
            switch self {
            case .jamfClientSecret:   return "Jamf client secret"
            case .intuneClientSecret: return "Intune client secret"
            case .intuneRefreshToken: return "Intune sign-in session"
            case .abmPrivateKey:      return "ABM private key"
            }
        }
    }

    enum KeychainError: Error, LocalizedError {
        case encodingFailed
        case unexpectedData
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return "Could not encode the value for storage."
            case .unexpectedData:
                return "Keychain returned data in an unexpected format."
            case let .unhandled(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    /// Save a secret, replacing any existing entry for the account.
    static func save(_ value: String, for account: Account) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete first: SecItemAdd fails on duplicates, and update-or-add
        // branching is more code for the same result.
        try? delete(account)

        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecValueData as String:   data,
            // Available only when the Mac is unlocked, and never synced to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Read a secret, or nil if not present.
    static func read(_ account: Account) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    /// Remove a stored secret.
    static func delete(_ account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Whether a secret exists, without returning it.
    static func exists(_ account: Account) -> Bool {
        ((try? read(account)) ?? nil) != nil
    }
}
