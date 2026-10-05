import Foundation
import Security

enum WitnessKeychain {
    private static let service = "com.swiftmesh.witness"
    private static let account = "authority-bearer-token"

    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return token
    }

    static func save(_ token: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account
        ]
        let changes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecValueData as String] = Data(token.utf8)
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    static func loadOrCreate(account: String = account) throws -> String {
        if let token = try read(account) {
            guard token.utf8.count >= 32 else { throw KeychainError(status: errSecDecode) }
            return token
        }
        let token = try randomToken()
        try save(token, account: account)
        return token
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain could not access the witness credential (\(status))." }
    }
}
