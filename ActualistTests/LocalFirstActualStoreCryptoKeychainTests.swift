import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func encryptionPasswordNoticeExplainsRecoveryResponsibility() {
        let notice = LocalFirstRecoveryGuidance.encryptionPasswordNotice

        #expect(notice.contains("cannot be recovered by Actualist"))
        #expect(notice.contains("Store it securely"))
        #expect(notice.contains("if this iPhone is lost or replaced"))
        #expect(notice.contains("not the password"))
        #expect(notice.contains("Neither is included in device backups"))
    }

    @Test func actualBudgetCryptoDerivesActualCompatibleKey() async throws {
        let key = try ActualBudgetCrypto.deriveKey(password: "correct horse", salt: "actual-salt")

        #expect(key.base64EncodedString() == "uXkIgygcn1EQ8xhItpxCuiICM9BxkdD5e0ZbBM+9nwE=")
    }

    @Test func actualBudgetCryptoValidatesUserKeyTestPayload() async throws {
        let password = "budget password"
        let salt = "server-salt"
        let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
        let context = ActualBudgetEncryptionContext(keyID: "key-1", keyData: keyData)
        let encrypted = try ActualBudgetCrypto.encrypt(Data("test-value".utf8), context: context)
        let testPayload = ActualUserKeyResponse.TestPayload(
            value: encrypted.data.base64EncodedString(),
            meta: ActualEncryptedMetadata(
                keyID: "key-1",
                algorithm: ActualBudgetCrypto.algorithm,
                iv: encrypted.iv.base64EncodedString(),
                authTag: encrypted.authTag.base64EncodedString()
            )
        )
        let response = ActualUserKeyResponse(
            id: "key-1",
            salt: salt,
            test: String(data: try JSONEncoder.actual.encode(testPayload), encoding: .utf8)
        )

        let validated = try ActualBudgetCrypto.validateUserKeyResponse(response, password: password)

        #expect(validated == context)
    }

    @Test func keychainStoreSurfacesFailuresAndRemovesOnlyBudgetEncryptionKeys() throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: "actual-sync-token",
            backend: backend
        )

        try keychain.saveActualSyncToken(" token ")
        try keychain.saveLocalFirstEncryptionKey(Data([1, 2, 3]), fileID: "file-1", keyID: "key-1")
        try keychain.removeAllLocalFirstEncryptionKeys()

        #expect(keychain.readActualSyncToken() == "token")
        #expect(keychain.readLocalFirstEncryptionKey(fileID: "file-1", keyID: "key-1") == nil)

        backend.updateFailureStatus = errSecAuthFailed
        #expect(throws: LocalFirstError.keychainFailure("save Keychain data", errSecAuthFailed)) {
            try keychain.saveActualSyncToken("next")
        }
    }

    @Test func keychainStorePersistsDefaultSecurityAttributesForEveryStoredItem() throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )

        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )
        try keychain.saveLocalFirstEncryptionKey(
            Data([4, 5, 6]),
            fileID: "file-2",
            keyID: "key-2"
        )

        let items = backend.storedItemAttributes(service: service)
        #expect(items.count == 3)
        #expect(
            Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
                == [
                    "actual-sync-token",
                    "actual-encryption-key:file-1:key-1",
                    "actual-encryption-key:file-2:key-2"
                ]
        )
        for item in items {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
            #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        }
    }

    @Test func keychainStoreAtomicallyPromotesEveryItemForBackgroundRefresh() throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )
        try keychain.saveLocalFirstEncryptionKey(
            Data([4, 5, 6]),
            fileID: "file-2",
            keyID: "key-2"
        )
        backend.resetUpdateCallCount()

        try keychain.promoteAllItemsForBackgroundRefresh()

        #expect(backend.updateCallCount == 1)
        let items = backend.storedItemAttributes(service: service)
        #expect(items.count == 3)
        for item in items {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
            #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        }
    }

    @Test func readingCredentialsDoesNotPromoteTheirAccessibility() throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )

        #expect(keychain.readActualSyncToken() == "token")
        #expect(
            keychain.readLocalFirstEncryptionKey(fileID: "file-1", keyID: "key-1")
                == Data([1, 2, 3])
        )

        for item in backend.storedItemAttributes(service: service) {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        }
    }

    @Test func keychainStoreFailedPromotionLeavesEveryItemUnchanged() throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )
        backend.resetUpdateCallCount()
        backend.updateFailureStatus = errSecAuthFailed

        #expect(
            throws: LocalFirstError.keychainFailure(
                "promote credentials for background refresh",
                errSecAuthFailed
            )
        ) {
            try keychain.promoteAllItemsForBackgroundRefresh()
        }

        #expect(backend.updateCallCount == 1)
        for item in backend.storedItemAttributes(service: service) {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        }
    }

    @Test func keychainStoreNeverDowngradesPromotedOrLaterItems() throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.promoteAllItemsForBackgroundRefresh()

        try keychain.saveActualSyncToken("replacement-token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "later-file",
            keyID: "later-key"
        )

        let items = backend.storedItemAttributes(service: service)
        #expect(items.count == 2)
        for item in items {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
        }
    }

    @Test func backgroundRefreshPromotionFailureDoesNotEnableSetting() async throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )
        backend.updateFailureStatus = errSecAuthFailed
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        let state = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            notificationAuthorizationRequester: { true }
        )

        await state.updateBackgroundTransactionRefreshEnabled(true)

        #expect(!state.settings.backgroundTransactionRefreshEnabled)
        #expect(!settingsStore.load().backgroundTransactionRefreshEnabled)
        #expect(
            state.lastErrorMessage
                == LocalFirstError.keychainFailure(
                    "promote credentials for background refresh",
                    errSecAuthFailed
                ).localizedDescription
        )
        for item in backend.storedItemAttributes(service: service) {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            )
        }
    }

    @Test func disablingBackgroundRefreshDoesNotDemoteCredentials() async throws {
        let backend = FakeKeychainBackend()
        let service = "com.sporez.actualist.tests"
        let keychain = KeychainStore(
            service: service,
            account: "actual-sync-token",
            backend: backend
        )
        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(
            Data([1, 2, 3]),
            fileID: "file-1",
            keyID: "key-1"
        )
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        let state = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            notificationAuthorizationRequester: { true }
        )

        await state.updateBackgroundTransactionRefreshEnabled(true)
        #expect(state.settings.backgroundTransactionRefreshEnabled)
        await state.updateBackgroundTransactionRefreshEnabled(false)

        #expect(!state.settings.backgroundTransactionRefreshEnabled)
        for item in backend.storedItemAttributes(service: service) {
            #expect(
                item[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
        }
    }

    @Test func fakeKeychainRejectsSaveWithoutAccessibility() {
        let backend = FakeKeychainBackend()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sporez.actualist.tests",
            kSecAttrAccount as String: "missing-accessibility",
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: Data("secret".utf8)
        ]

        #expect(backend.add(query as CFDictionary, result: nil) == errSecParam)
        #expect(backend.storedItemAttributes(service: "com.sporez.actualist.tests").isEmpty)
    }

    @Test func eraseLocalDataRemovesCredentialsKeysAndImportedBudgetDirectories() async throws {
        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: "actual-sync-token",
            backend: backend
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistErase-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let store = LocalFirstActualStore(keychain: keychain, fileManager: fileManager)

        try keychain.saveActualSyncToken("token")
        try keychain.saveLocalFirstEncryptionKey(Data([4, 5, 6]), fileID: "file-1", keyID: "key-1")
        try FileManager.default.createDirectory(
            at: fileManager.budgetDirectory(fileID: "file-1"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fileManager.budgetDirectory(fileID: "file-2"),
            withIntermediateDirectories: true
        )

        try store.eraseLocalData()

        #expect(keychain.readActualSyncToken().isEmpty)
        #expect(keychain.readLocalFirstEncryptionKey(fileID: "file-1", keyID: "key-1") == nil)
        #expect(try fileManager.importedBudgetFileIDs().isEmpty)
        #expect(!store.hasOpenBudget)
    }
}
