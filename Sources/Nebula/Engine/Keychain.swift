import Foundation
import Security

/// The Anthropic API key. Nebula uses its own if you've set one, otherwise Nova's
/// (the same key, already in your keychain): service ai.galaxy.nova, account anthropic-api-key.
enum Keychain {
    private static let account = "anthropic-api-key"
    static let nebulaService = "ai.galaxy.nebula"
    static let novaService = "ai.galaxy.nova"

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return read(nebulaService) ?? read(novaService)
    }

    /// Where the key in use comes from, for Settings.
    static var source: String? {
        if read(nebulaService) != nil { return "Nebula's own key" }
        if read(novaService) != nil { return "Nova's key" }
        return nil
    }

    private static func read(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func saveNebulaKey(_ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nebulaService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteNebulaKey() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: nebulaService,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
