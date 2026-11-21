import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the two DeepSeek credentials: the
/// `sk-` API key used for balance and the platform `userToken` used for usage.
///
/// The reference app (ClaudeUsageBar) keeps its session cookie in
/// `UserDefaults`, which is an unencrypted plist — the weakest part of that
/// design. A credential that grants access to account usage and billing
/// history belongs in the Keychain.
enum Keychain {
    private static let service = "com.krisrimar.deepseek-usage-bar"

    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete first: SecItemAdd fails with errSecDuplicateItem otherwise,
        // and there is no atomic upsert in the legacy API.
        _ = delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Available without an unlocked login keychain prompt, but never
            // synced off the machine or backed up to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static let userTokenAccount = "platform-user-token"
    static let apiKeyAccount = "api-key"
}
