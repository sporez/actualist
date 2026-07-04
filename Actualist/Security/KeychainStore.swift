import Foundation
import Security

struct KeychainStore {
    static let actualist = KeychainStore(service: "com.sporez.actualist", account: "actual-http-api-key")

    let service: String
    let account: String

    func readAPIKey() -> String {
        readValue()
    }

    func saveAPIKey(_ apiKey: String) {
        saveValue(apiKey)
    }

    func readActualSyncToken() -> String {
        scoped(account: "actual-sync-token").readValue()
    }

    func saveActualSyncToken(_ token: String) {
        scoped(account: "actual-sync-token").saveValue(token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func removeActualSyncToken() {
        SecItemDelete(scoped(account: "actual-sync-token").baseQuery() as CFDictionary)
    }

    private func scoped(account: String) -> KeychainStore {
        KeychainStore(service: service, account: account)
    }

    private func readValue() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }

        updateAccessibilityForBackgroundRefresh()
        return value
    }

    private func saveValue(_ value: String) {
        let data = Data(value.utf8)
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
