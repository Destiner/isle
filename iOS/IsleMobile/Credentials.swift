import Foundation
import Security

nonisolated enum MobileKeychain {
    private static let service = "DestinerLabs.IsleMobile"

    static func string(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return true
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

nonisolated enum MobileOpenRouterCredentials {
    private static let account = "openrouter-api-key"

    static func bootstrapFromEnvironment() {
        guard let environmentKey = ProcessInfo.processInfo.environment["ISLE_OPENROUTER_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !environmentKey.isEmpty else { return }
        MobileKeychain.set(environmentKey, account: account)
    }

    static var key: String? {
        if let environmentKey = ProcessInfo.processInfo.environment["ISLE_OPENROUTER_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            MobileKeychain.set(environmentKey, account: account)
            return environmentKey
        }

        return MobileKeychain.string(account: account)
    }
}
