//
//  Keychain.swift
//  Isle
//

import Foundation
import Security

/// A tiny wrapper over the login-keychain generic-password store. Isle runs with the
/// App Sandbox off (see the fn-key gotcha), so items land in the login keychain with
/// no keychain-sharing entitlement. One service (`DestinerLabs.Isle`, matching the
/// code identity), keyed by account.
nonisolated enum Keychain {
    static let service = "DestinerLabs.Isle"

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
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)  // replace-if-present
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// Where the Fastmail JMAP bearer token comes from. The `ISLE_JMAP_TOKEN` env var
/// wins (handy for a terminal-launched dev run); otherwise the Keychain, seeded once
/// with `security add-generic-password -s DestinerLabs.Isle -a fastmail-jmap-token -w <TOKEN>`
/// (or `Keychain.set(_:account:)`). Never a committed constant.
nonisolated enum FastmailCredentials {
    static let keychainAccount = "fastmail-jmap-token"

    static var token: String? {
        if let env = ProcessInfo.processInfo.environment["ISLE_JMAP_TOKEN"], !env.isEmpty {
            return env
        }
        return Keychain.string(account: keychainAccount)
    }
}
