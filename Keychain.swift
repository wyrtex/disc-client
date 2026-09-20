import Foundation
import Security

enum Keychain {
    private static let account = "discord-token"
    private static let fallbackKey = "token-fallback"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        // При переподписи через сторонние инструменты Keychain иногда недоступен.
        if status != errSecSuccess {
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: fallbackKey)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }
}
