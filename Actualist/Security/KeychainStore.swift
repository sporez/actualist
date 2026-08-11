import Foundation
import Security

protocol KeychainBackend {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainBackend: KeychainBackend {
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct KeychainStore {
    static let actualist = KeychainStore(service: "com.sporez.actualist", account: "actual-sync-token")

    let service: String
    let account: String
    var backend: any KeychainBackend = SystemKeychainBackend()

    func readActualSyncToken() -> String {
        guard let data = readData(),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    func saveActualSyncToken(_ token: String) throws {
        try saveData(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    func removeActualSyncToken() throws {
        try deleteData(operation: "remove the sync token")
    }

    func readLocalFirstEncryptionKey(fileID: String, keyID: String) -> Data? {
        scoped(account: Self.encryptionKeyAccount(fileID: fileID, keyID: keyID)).readData()
    }

    func saveLocalFirstEncryptionKey(_ keyData: Data, fileID: String, keyID: String) throws {
        try scoped(account: Self.encryptionKeyAccount(fileID: fileID, keyID: keyID)).saveData(keyData)
    }

    func removeLocalFirstEncryptionKey(fileID: String, keyID: String) throws {
        try scoped(account: Self.encryptionKeyAccount(fileID: fileID, keyID: keyID))
            .deleteData(operation: "remove the budget encryption key")
    }

    func removeAllLocalFirstEncryptionKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = backend.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw LocalFirstError.keychainFailure("list budget encryption keys", status)
        }

        let items = result as? [[String: Any]] ?? []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(Self.encryptionKeyAccountPrefix) else {
                continue
            }
            try scoped(account: account).deleteData(operation: "remove budget encryption keys")
        }
    }

    func promoteAllItemsForBackgroundRefresh() throws {
        let attributes = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // Promote every item in one Keychain operation.
        let status = backend.update(
            allServiceItemsQuery() as CFDictionary,
            attributes: attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw LocalFirstError.keychainFailure(
                "promote credentials for background refresh",
                status
            )
        }
    }

    private func scoped(account: String) -> KeychainStore {
        KeychainStore(service: service, account: account, backend: backend)
    }

    private static let encryptionKeyAccountPrefix = "actual-encryption-key:"

    private static func encryptionKeyAccount(fileID: String, keyID: String) -> String {
        "\(encryptionKeyAccountPrefix)\(fileID):\(keyID)"
    }

    private func readData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = backend.copyMatching(query as CFDictionary, result: &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private func saveData(_ data: Data) throws {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = backend.update(query as CFDictionary, attributes: attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = try accessibilityForNewItem()
            let addStatus = backend.add(addQuery as CFDictionary, result: nil)
            guard addStatus == errSecSuccess else {
                throw LocalFirstError.keychainFailure("save Keychain data", addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw LocalFirstError.keychainFailure("save Keychain data", status)
        }
    }

    private func deleteData(operation: String) throws {
        let status = backend.delete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalFirstError.keychainFailure(operation, status)
        }
    }

    private func accessibilityForNewItem() throws -> CFString {
        var query = allServiceItemsQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: AnyObject?
        let status = backend.copyMatching(query as CFDictionary, result: &result)
        if status == errSecItemNotFound {
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        guard status == errSecSuccess else {
            throw LocalFirstError.keychainFailure(
                "inspect credential accessibility",
                status
            )
        }

        let items = result as? [[String: Any]] ?? []
        let promotedAccessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        // Synchronizable promotion is one-way for this service.
        if items.contains(where: {
            ($0[kSecAttrAccessible as String] as? String) == promotedAccessibility
        }) {
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private func allServiceItemsQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func baseQuery() -> [String: Any] {
        var query = allServiceItemsQuery()
        query[kSecAttrAccount as String] = account
        return query
    }
}
