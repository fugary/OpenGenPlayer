import Foundation
import Security

public enum KeychainService {
    public static func set(_ value: String, for key: String) -> Bool {
        #if os(macOS)
        let data = value.data(using: .utf8)?.base64EncodedString()
        UserDefaults.standard.set(data, forKey: "KeychainFallback_\(key)")
        return true
        #else
        let data = Data(value.utf8)
        
        delete(for: key)
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "GenPlayer",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecUseDataProtectionKeychain as String: true
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
        #endif
    }

    public static func get(for key: String) -> String? {
        #if os(macOS)
        guard let base64String = UserDefaults.standard.string(forKey: "KeychainFallback_\(key)"),
              let data = Data(base64Encoded: base64String),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\0"))
        #else
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "GenPlayer",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Trim invisible characters (like newlines or trailing null bytes) that might have been carried over from legacy migrations
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\0"))
        #endif
    }

    public static func delete(for key: String) {
        #if os(macOS)
        UserDefaults.standard.removeObject(forKey: "KeychainFallback_\(key)")
        #else
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "GenPlayer",
            kSecUseDataProtectionKeychain as String: true
        ]

        SecItemDelete(query as CFDictionary)
        #endif
    }
}
