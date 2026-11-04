import Foundation
import Security

/// Generic-password item, readable after first unlock so a BLE wake-up in the
/// background can still reach the key. Kept in an access group the app and
/// the keyboard share, so the keyboard can rewrite text with the same key.
enum Keychain {
    private static let service = "com.suko.stickdictation"

    /// From Info.plist (`$(AppIdentifierPrefix)` + bundle prefix). Missing when
    /// the build has no shared group, e.g. a re-signed sideload.
    private static let group = Bundle.main.object(forInfoDictionaryKey: "StickKeychainGroup") as? String

    static func read(_ account: String) -> String? {
        if let group, let value = read(account, group: group) { return value }
        // Saved before the shared group existed: move it there.
        guard let value = read(account, group: nil) else { return nil }
        if group != nil { write(value, for: account) }
        return value
    }

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        var base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group { base[kSecAttrAccessGroup as String] = group }
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func read(_ account: String, group: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
