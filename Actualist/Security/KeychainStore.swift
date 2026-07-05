import Foundation
import Security

struct KeychainStore {
    static let actualist = KeychainStore(service: "com.sporez.actualist", account: "actual-sync-token")

    let service: String
    let account: String

    func readActualSyncToken() -> String {
        guard let data = readData(),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    func saveActualSyncToken(_ token: String) {
        saveData(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
    }

    func removeActualSyncToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    func readLocalFirstEncryptionKey(fileID: String, keyID: String) -> Data? {
        scoped(account: Self.encryptionKeyAccount(fileID: fileID, keyID: keyID)).readData()
    }

    func saveLocalFirstEncryptionKey(_ keyData: Data, fileID: String, keyID: String) {
        scoped(account: Self.encryptionKeyAccount(fileID: fileID, keyID: keyID)).saveData(keyData)
    }

    private func scoped(account: String) -> KeychainStore {
        KeychainStore(service: service, account: account)
    }

    private static func encryptionKeyAccount(fileID: String, keyID: String) -> String {
        "actual-encryption-key:\(fileID):\(keyID)"
    }

    private func readData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        updateAccessibilityForBackgroundRefresh()
        return data
    }

    private func saveData(_ data: Data) {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func updateAccessibilityForBackgroundRefresh() {
        let attributes = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
