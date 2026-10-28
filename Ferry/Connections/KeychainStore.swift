import Foundation
import Security

/// Stores connection secrets as generic passwords, one item per connection and field.
enum KeychainStore {
    private static let service = "com.zhanghongshen.Ferry.connection"

    private enum Field: String, CaseIterable {
        case password
        case secretKey
        case privateKey
        case passphrase
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }

    static func secrets(for id: UUID) throws -> ConnectionSecrets {
        ConnectionSecrets(
            password: try read(.password, id: id) ?? "",
            secretKey: try read(.secretKey, id: id) ?? "",
            privateKey: try read(.privateKey, id: id) ?? "",
            passphrase: try read(.passphrase, id: id) ?? ""
        )
    }

    /// Saves non-empty fields and removes empty ones.
    static func save(_ secrets: ConnectionSecrets, for id: UUID) throws {
        try write(secrets.password, field: .password, id: id)
        try write(secrets.secretKey, field: .secretKey, id: id)
        try write(secrets.privateKey, field: .privateKey, id: id)
        try write(secrets.passphrase, field: .passphrase, id: id)
    }

    static func deleteSecrets(for id: UUID) throws {
        for field in Field.allCases {
            try delete(field, id: id)
        }
    }

    private static func baseQuery(_ field: Field, id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(id.uuidString)/\(field.rawValue)",
        ]
    }

    private static func read(_ field: Field, id: UUID) throws -> String? {
        var query = baseQuery(field, id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private static func write(_ value: String, field: Field, id: UUID) throws {
        guard !value.isEmpty else {
            try delete(field, id: id)
            return
        }
        let data = Data(value.utf8)
        let query = baseQuery(field, id: id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private static func delete(_ field: Field, id: UUID) throws {
        let status = SecItemDelete(baseQuery(field, id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
