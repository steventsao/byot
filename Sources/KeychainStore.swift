import Foundation
import Security

enum KeychainStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.steventsao.byot"
    }

    static func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) throws {
        let valueData = Data(value.utf8)
        let query = baseQuery(for: key)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: valueData] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = valueData
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    static func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        try validateDeleteStatus(status)
    }

    static func validateDeleteStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var statusCode: OSStatus {
        switch self {
        case .unexpectedStatus(let status):
            status
        }
    }

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}
