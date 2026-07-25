import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

@MainActor
struct LocalFirstActualStoreTests {
    enum ReimportFailureScenario: CaseIterable, Sendable {
        case midDownload
        case midDecrypt
        case midExtract
        case corruptArchive
        case wrongSchema
    }

    private struct OpenedWritableStoreBundle {
        let store: LocalFirstActualStore
        let fileManager: BudgetFileManager
        let keychain: KeychainStore
        let budget: ActualBudget
    }

    @Test func categoryMonthFilterIncludesDirectAndSplitTransactionsOnlyForRequestedMonth() throws {
        let direct = makeTransaction(id: "direct", category: "groceries")
        let otherCategory = makeTransaction(id: "utilities", category: "utilities")
        let otherMonth = makeTransaction(id: "old", category: "groceries", date: "2026-06-30")
        let splitChild = makeTransaction(id: "split-child", category: "groceries")
        let splitParent = makeTransaction(
            id: "split-parent",
            category: nil,
            isParent: true,
            subtransactions: [splitChild]
        )
        let loaded = LoadedAccountTransactions(
            transactions: [direct, otherCategory, otherMonth, splitParent],
            balance: 99,
            accountNames: ["checking": "Checking"],
            categoryNames: ["groceries": "Groceries"],
            payeeNames: [:],
            transferPayeeIDs: [],
            transferAccountIDsByPayeeID: ["transfer-tracking": "tracking"],
            offBudgetAccountIDs: ["tracking"],
            reachedEnd: true
        )

        let filtered = loaded.filtering(categoryID: "groceries", month: "2026-07")

        #expect(filtered.transactions.map(\.id) == ["direct", "split-parent"])
        #expect(filtered.balance == nil)
        #expect(filtered.accountNames == loaded.accountNames)
        #expect(filtered.transferAccountIDsByPayeeID == loaded.transferAccountIDsByPayeeID)
        #expect(filtered.offBudgetAccountIDs == loaded.offBudgetAccountIDs)
        #expect(filtered.reachedEnd)
    }

    @Test func categoryMonthFeedLoadsACompleteLocalSnapshot() async throws {
        let store = try await makeOpenedWritableStore()

        try await store.refreshCategoryTransactions(
            budgetID: "group-1",
            categoryID: "groceries",
            month: "2026-07"
        )

        let loaded = try #require(store.cachedCategoryTransactions(
            budgetID: "group-1",
            categoryID: "groceries",
            month: "2026-07"
        ))
        #expect(loaded.transactions.map(\.id) == ["txn"])
        #expect(loaded.categoryNames["groceries"] == "Groceries")
        #expect(loaded.accountNames["checking"] == "Checking")
        #expect(loaded.reachedEnd)
    }

    @Test func settingsDecodeIgnoresRetiredRestKeysAndKeepsLocalFirst() async throws {
        // Old persisted settings may still carry retired REST keys; they must be ignored while
        // local-first fields decode normally.
        let data = Data("""
        {
          "backendMode": "restAPI",
          "serverURLString": "http://localhost:5007/v1",
          "localFirstServerURLString": "https://actual.example.com",
          "selectedBudgetID": "budget",
          "enabledExperimentalFeatures": ["retiredFeature"]
        }
        """.utf8)

        let settings = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(settings.localFirstServerURLString == "https://actual.example.com")
        #expect(settings.selectedBudgetID == "budget")
        #expect(settings.selectedLocalFirstFileID == nil)
        #expect(settings.enabledExperimentalFeatures.isEmpty)
        #expect(settings.reportCardOrder == ReportCardOrderPreference.defaultOrder)
        #expect(settings.localFirstSyncDebug == LocalFirstSyncDebugInfo())
        #expect(!settings.greenIncomeTransactionAmountsEnabled)
        #expect(!settings.includeCarryoverCategoriesInOverspentAlerts)
        #expect(settings.appSwitcherPrivacyMode == .whenBackgrounded)
    }

    @Test func greenIncomeTransactionAmountsPreferencePersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let settings = AppSettings(greenIncomeTransactionAmountsEnabled: true)

        store.save(settings)

        #expect(store.load().greenIncomeTransactionAmountsEnabled)
    }

    @Test func carryoverOverspendingAlertPreferenceDefaultsOffAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(!AppSettings().includeCarryoverCategoriesInOverspentAlerts)

        let settings = AppSettings(includeCarryoverCategoriesInOverspentAlerts: true)
        store.save(settings)

        #expect(store.load().includeCarryoverCategoriesInOverspentAlerts)
    }

    @Test func appSwitcherPrivacyPreferenceDefaultsToBackgroundAndPersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)

        #expect(AppSettings().appSwitcherPrivacyMode == .whenBackgrounded)

        let settings = AppSettings(appSwitcherPrivacyMode: .always)
        store.save(settings)

        #expect(store.load().appSwitcherPrivacyMode == .always)
    }

    @Test(arguments: [
        (AppSwitcherPrivacyMode.off, ScenePhase.active, false, false),
        (.off, .inactive, false, false),
        (.off, .background, false, false),
        (.whenBackgrounded, .active, false, false),
        (.whenBackgrounded, .inactive, false, false),
        (.whenBackgrounded, .background, false, true),
        (.whenBackgrounded, .background, true, true),
        (.always, .active, false, false),
        (.always, .inactive, false, true),
        (.always, .background, false, true),
        (.always, .inactive, true, false),
        (.always, .background, true, false)
    ])
    func appSwitcherSnapshotPolicyMatchesConfiguredLifecycleBehavior(
        mode: AppSwitcherPrivacyMode,
        phase: ScenePhase,
        isSuppressed: Bool,
        expected: Bool
    ) {
        #expect(
            AppSwitcherSnapshotPolicy.shouldCover(
                mode: mode,
                scenePhase: phase,
                isAppInitiatedSystemUISuppressed: isSuppressed
            ) == expected
        )
    }

    @Test func appSwitcherSystemUISuppressionOnlyAppliesToAlwaysModeAndClears() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let state = AppState(settingsStore: AppSettingsStore(defaults: defaults))

        state.beginAppInitiatedSystemUIPresentation()
        #expect(!state.isAppSwitcherCoverSuppressedForSystemUI)

        state.updateAppSwitcherPrivacyMode(.always)
        state.beginAppInitiatedSystemUIPresentation()
        #expect(state.isAppSwitcherCoverSuppressedForSystemUI)

        state.clearAppInitiatedSystemUIPresentationSuppression()
        #expect(!state.isAppSwitcherCoverSuppressedForSystemUI)
    }

    @Test func localFirstSyncDiagnosticsPersistInSettings() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let event = LocalFirstSyncDebugEvent(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_788_000_000),
            outcome: .failed,
            pendingBefore: 5,
            uploadedCount: 0,
            downloadedCount: 0,
            pendingAfter: 5,
            message: "Network unavailable"
        )
        var settings = AppSettings()
        settings.localFirstSyncDebug = LocalFirstSyncDebugInfo(totalEventCount: 1, recentEvents: [event])

        store.save(settings)

        #expect(store.load().localFirstSyncDebug == settings.localFirstSyncDebug)
    }

    @Test func experimentalFeaturesPersistInSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        var settings = AppSettings()
        settings.enabledExperimentalFeatures = [.budgetTemplates]

        store.save(settings)

        #expect(store.load().enabledExperimentalFeatures == [.budgetTemplates])
    }

    @Test func reportCardOrderPersistsAndRepairsMissingCards() throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let store = AppSettingsStore(defaults: defaults)
        let customOrder = Array(ReportCardOrderPreference.defaultOrder.reversed())
        let settings = AppSettings(reportCardOrder: customOrder)

        store.save(settings)

        #expect(store.load().reportCardOrder == customOrder)

        let partialData = Data(#"{"reportCardOrder":["cashFlow","unknown","cashFlow"]}"#.utf8)
        let repaired = try JSONDecoder.actual.decode(AppSettings.self, from: partialData)
        #expect(repaired.reportCardOrder.first == .cashFlow)
        #expect(repaired.reportCardOrder.count == ReportCardKind.allCases.count)
        #expect(Set(repaired.reportCardOrder) == Set(ReportCardKind.allCases))
    }

    @Test func loginResponseDecodesTopLevelAndNestedToken() async throws {
        let topLevel = try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"token":"abc"}"#.utf8)
        )
        let nested = try JSONDecoder.actual.decode(
            ActualLoginResponse.self,
            from: Data(#"{"data":{"token":"def"}}"#.utf8)
        )

        #expect(topLevel.token == "abc")
        #expect(nested.token == "def")
    }

    @Test func serverConnectionSecurityAllowsHTTPSWithoutWarning() async {
        #expect(ActualServerConnectionSecurity.warningMessage(for: "actual.example.com") == nil)
        #expect(ActualServerConnectionSecurity.blockedMessage(for: "actual.example.com") == nil)
    }

    @Test func serverConnectionSecurityWarnsForLocalHTTP() async {
        #expect(
            ActualServerConnectionSecurity.warningMessage(for: "http://192.168.1.16:5007")
                == ActualServerConnectionSecurity.localHTTPWarning
        )
        #expect(ActualServerConnectionSecurity.blockedMessage(for: "http://192.168.1.16:5007") == nil)
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("server password"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("long-lived sync token"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("every request"))
        #expect(ActualServerConnectionSecurity.localHTTPWarning.contains("intercept"))
    }

    @Test(arguments: [
        "http://100.64.0.1:5006",
        "http://100.127.255.254:5006",
        "http://actual.tailnet-name.ts.net:5006",
        "http://[fc00::1]:5006",
        "http://[fd12:3456:789a::1]:5006",
        "http://[fe80::1]:5006",
        "http://[fe80::1%25en0]:5006",
        "http://[::ffff:192.168.1.20]:5006"
    ])
    func serverConnectionSecurityAllowsLocalAndTailnetHTTP(_ input: String) {
        #expect(
            ActualServerConnectionSecurity.warningMessage(for: input)
                == ActualServerConnectionSecurity.localHTTPWarning
        )
        #expect(ActualServerConnectionSecurity.blockedMessage(for: input) == nil)
    }

    @Test(arguments: [
        "http://100.63.255.255:5006",
        "http://100.128.0.1:5006",
        "http://[2001:db8::1]:5006",
        "http://actual.internal:5006"
    ])
    func serverConnectionSecurityBlocksNonlocalHTTP(_ input: String) {
        #expect(ActualServerConnectionSecurity.warningMessage(for: input) == nil)
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: input)
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func serverConnectionSecurityBlocksRemoteHTTP() async {
        #expect(ActualServerConnectionSecurity.warningMessage(for: "http://actual.example.com") == nil)
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: "http://actual.example.com")
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func serverConnectionSecurityDoesNotResolveUnrecognizedHostnames() {
        // Even if local DNS maps this name to RFC1918 space, the lexical policy blocks it.
        #expect(
            ActualServerConnectionSecurity.blockedMessage(for: "http://budget.home.arpa:5006")
                == ActualServerConnectionSecurity.remoteHTTPBlockedMessage
        )
    }

    @Test func loginMethodsDecodeActualServerObjectShape() async throws {
        let response = try JSONDecoder.actual.decode(
            ActualLoginMethodsResponse.self,
            from: Data("""
            {
              "status": "ok",
              "methods": [
                { "method": "password", "active": 1, "displayName": "Password" },
                { "method": "openid", "active": 0, "displayName": "OpenID" }
              ]
            }
            """.utf8)
        )

        #expect(response.methods == ["password"])
    }

    @Test func userFilesDecodeDeletedFilteringInputs() async throws {
        let data = Data("""
        {
          "groupId": "group-1",
          "files": [
            { "fileId": "file-1", "name": "Main" },
            { "fileId": "file-2", "name": "Old", "deleted": true }
          ]
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFilesResponse.self, from: data)
        let visible = response.files.filter { !$0.deleted }

        #expect(visible.map(\.fileID) == ["file-1"])
        #expect(visible.first?.name == "Main")
    }

    @Test func userFilesDecodeActualServerDataArrayShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": [
            {
              "deleted": 0,
              "encryptKeyId": "key-1",
              "fileId": "file-1",
              "groupId": "group-1",
              "name": "My Budget",
              "owner": "user-1",
              "usersWithAccess": [
                {
                  "displayName": "",
                  "owner": true,
                  "userId": "user-1",
                  "userName": ""
                }
              ]
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFilesResponse.self, from: data)

        #expect(response.groupID == nil)
        #expect(response.files.count == 1)
        #expect(response.files.first?.fileID == "file-1")
        #expect(response.files.first?.groupID == "group-1")
        #expect(response.files.first?.name == "My Budget")
        #expect(response.files.first?.deleted == false)
        #expect(response.files.first?.encryptKeyID == "key-1")
        #expect(response.files.first?.requiresEncryptionPassword == false)
        #expect(response.files.first?.syncEncryptionKeyID == nil)
    }

    @Test func userFileInfoDecodesActualServerDataObjectShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "deleted": 0,
            "encryptKeyId": "key-1",
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget"
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.fileID == "file-1")
        #expect(response.file?.groupID == "group-1")
        #expect(response.file?.encryptKeyID == "key-1")
        #expect(response.file?.requiresEncryptionPassword == false)
        #expect(response.file?.syncEncryptionKeyID == nil)
    }

    @Test func userFileInfoTreatsNullEncryptMetaAsUnencrypted() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget",
            "encryptMeta": null
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.requiresEncryptionPassword == false)
    }

    @Test func userFileInfoDetectsEncryptedDownloadMetadata() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "fileId": "file-1",
            "groupId": "group-1",
            "name": "My Budget",
            "encryptMeta": {
              "keyId": "key-1"
            }
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserFileInfoResponse.self, from: data)

        #expect(response.file?.requiresEncryptionPassword == true)
        #expect(response.file?.syncEncryptionKeyID == "key-1")
    }

    @Test func userKeyResponseDecodesNestedActualServerShape() async throws {
        let data = Data("""
        {
          "status": "ok",
          "data": {
            "id": "key-1",
            "salt": "salt-1",
            "test": "{\\"value\\":\\"abc\\",\\"meta\\":{\\"keyId\\":\\"key-1\\",\\"algorithm\\":\\"aes-256-gcm\\",\\"iv\\":\\"MTIzNDU2Nzg5MDEy\\",\\"authTag\\":\\"YWJjZGVmZ2hpamtsbW5vcA==\\"}}"
          }
        }
        """.utf8)

        let response = try JSONDecoder.actual.decode(ActualUserKeyResponse.self, from: data)

        #expect(response.id == "key-1")
        #expect(response.salt == "salt-1")
        #expect(response.test?.contains("aes-256-gcm") == true)
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

    @Test func budgetFileManagerHashesAndValidatesServerFileIDs() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetPaths-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)

        for fileID in ["", ".", "..", "../..", "%2e%2e%2f..", "bad\0id"] {
            #expect(throws: LocalFirstError.invalidBudgetFileID) {
                _ = try fileManager.budgetDirectory(fileID: fileID)
            }
        }

        let longID = String(repeating: "budget-", count: 10_000)
        let directory = try fileManager.budgetDirectory(fileID: longID)
        #expect(directory.lastPathComponent.count == 64)
        #expect(!directory.path.contains(longID))
    }

    @Test func budgetFileManagerRejectsSymlinkEscapeFromBudgetRoot() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetSymlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        let supportURL = baseURL.appending(path: "support", directoryHint: .isDirectory)
        let outsideURL = baseURL.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: supportURL.appending(path: "Budgets"),
            withDestinationURL: outsideURL
        )

        let fileManager = BudgetFileManager(applicationSupportURL: supportURL)
        #expect(throws: LocalFirstError.invalidBudgetFileID) {
            _ = try fileManager.databaseURL(fileID: "safe-id")
        }
    }

    @Test func importedBudgetDiscoveryReturnsMetadataFileIDNotHashedDirectoryName() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetDiscovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fileID = "server-file-id"
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: nil,
            budgetName: "Budget",
            encryptionKeyID: nil,
            nodeID: "node"
        )
        try JSONEncoder.actual.encode(metadata).write(to: fileManager.metadataURL(fileID: fileID))

        #expect(try fileManager.importedBudgetFileIDs() == [fileID])
    }

    @Test func budgetArchiveImportAcceptsAValidStagedArchive() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetArchive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            resourceLimits: testResourceLimits()
        )
        let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")
        try makeArchive(at: stagingURL, entries: [("nested/db.sqlite", Data("sqlite".utf8))])

        let databaseURL = try fileManager.importBudgetZip(
            at: stagingURL,
            remoteFile: testRemoteFile(),
            metadata: testBudgetMetadata()
        )

        #expect(try Data(contentsOf: databaseURL) == Data("sqlite".utf8))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test func cachedBudgetHardeningReappliesEffectiveSecurityToEveryArtifact() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistBudgetHardening-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let directory = try fileManager.budgetDirectory(fileID: "file-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try fileManager.databaseURL(fileID: "file-1")
        let metadata = try fileManager.metadataURL(fileID: "file-1")
        let artifacts = [
            directory,
            database,
            metadata,
            directory.appending(path: "db.sqlite-wal"),
            directory.appending(path: "db.sqlite-shm"),
            directory.appending(path: "db.sqlite-journal")
        ]
        for artifact in artifacts.dropFirst() {
            #expect(FileManager.default.createFile(atPath: artifact.path, contents: Data()))
        }
        for artifact in artifacts {
            try markBudgetArtifactAsUnhardened(artifact)
        }

        #expect(
            Set(try fileManager.cachedBudgetArtifacts(fileID: "file-1").map(\.lastPathComponent))
                == Set([
                    directory.lastPathComponent,
                    "db.sqlite",
                    "metadata.json",
                    "db.sqlite-wal",
                    "db.sqlite-shm",
                    "db.sqlite-journal"
                ])
        )
        try fileManager.hardenCachedBudget(fileID: "file-1")

        for artifact in artifacts {
            try expectBudgetArtifactIsHardened(artifact)
        }
    }

    @Test func openingCachedBudgetRunsHardeningBeforeAndAfterDatabaseOpen() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCachedOpenHardening-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fileID = "file-1"
        let directory = try fileManager.budgetDirectory(fileID: fileID)
        let database = try fileManager.databaseURL(fileID: fileID)
        let metadata = try fileManager.metadataURL(fileID: fileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: makeSQLiteFixture(),
            to: database
        )
        try JSONEncoder.actual.encode(testBudgetMetadata())
            .write(to: metadata)
        for artifact in [directory, database, metadata] {
            try markBudgetArtifactAsUnhardened(artifact)
        }
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            ),
            fileManager: fileManager
        )

        #expect(
            try await store.openCachedBudget(
                ActualBudget(
                    budgetID: fileID,
                    cloudFileId: fileID,
                    groupId: "group-1",
                    name: "Budget",
                    state: nil
                )
            )
        )

        let sidecars = ["-wal", "-shm", "-journal"].map {
            directory.appending(path: "db.sqlite\($0)")
        }
        for artifact in [directory, database, metadata]
            + sidecars.filter({ FileManager.default.fileExists(atPath: $0.path) }) {
            try expectBudgetArtifactIsHardened(artifact)
        }
    }

    @Test func budgetArchiveImportRejectsZipSlipAndEveryArchiveQuota() throws {
        struct ArchiveCase {
            let name: String
            let limits: LocalFirstResourceLimits
            let entries: [(String, Data)]
            let expectedError: LocalFirstError
        }

        let cases = [
            ArchiveCase(
                name: "zip-slip",
                limits: testResourceLimits(),
                entries: [("../escape/db.sqlite", Data("sqlite".utf8))],
                expectedError: .invalidDownloadedBudget
            ),
            ArchiveCase(
                name: "absolute",
                limits: testResourceLimits(),
                entries: [("/escape/db.sqlite", Data("sqlite".utf8))],
                expectedError: .invalidDownloadedBudget
            ),
            ArchiveCase(
                name: "entry-size",
                limits: testResourceLimits(maximumArchiveEntryBytes: 4),
                entries: [("db.sqlite", Data("12345".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "expanded-size",
                limits: testResourceLimits(maximumExpandedBudgetBytes: 6),
                entries: [("first", Data("1234".utf8)), ("db.sqlite", Data("5678".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "entry-count",
                limits: testResourceLimits(maximumArchiveEntryCount: 1),
                entries: [("first", Data("1".utf8)), ("db.sqlite", Data("2".utf8))],
                expectedError: .remoteDataLimitExceeded
            ),
            ArchiveCase(
                name: "path-depth",
                limits: testResourceLimits(maximumArchivePathDepth: 2),
                entries: [("one/two/db.sqlite", Data("sqlite".utf8))],
                expectedError: .remoteDataLimitExceeded
            )
        ]

        for archiveCase in cases {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(
                    path: "ActualistBudgetArchive-\(archiveCase.name)-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
            let fileManager = BudgetFileManager(
                applicationSupportURL: rootURL,
                resourceLimits: archiveCase.limits
            )
            let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")
            try makeArchive(at: stagingURL, entries: archiveCase.entries)

            #expect(throws: archiveCase.expectedError) {
                _ = try fileManager.importBudgetZip(
                    at: stagingURL,
                    remoteFile: testRemoteFile(),
                    metadata: testBudgetMetadata()
                )
            }
            #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
            let importDirectory = try fileManager.budgetDirectory(fileID: "file-1")
                .appending(path: "import")
            #expect(
                !FileManager.default.fileExists(
                    atPath: importDirectory.path
                )
            )
        }
    }

    @Test func stagedBudgetDownloadEnforcesCompressedSizeLimit() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCompressedLimit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            resourceLimits: testResourceLimits(maximumCompressedBudgetBytes: 4)
        )
        let stagingURL = try fileManager.prepareDownloadStaging(fileID: "file-1")

        #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try fileManager.replaceStagedDownload(
                at: stagingURL,
                with: Data(repeating: 0x41, count: 5)
            )
        }
    }

    @Test func failedInitialDownloadRemovesThePartialArchive() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDownloadCleanup-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        try keychain.saveActualSyncToken("token")
        let transport = StubConnectionTransport(
            failurePoint: .download,
            files: [testRemoteFile()],
            downloadData: Data("partial archive".utf8)
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            connectionTransportFactory: { _ in transport }
        )

        await #expect(throws: LocalFirstTestSyncError.failed) {
            try await store.openBudget(
                ActualBudget(
                    budgetID: "file-1",
                    cloudFileId: "file-1",
                    groupId: "group-1",
                    name: "Budget",
                    state: nil
                ),
                serverURLString: "https://sync.example"
            )
        }

        let directory = try fileManager.budgetDirectory(fileID: "file-1")
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appending(path: "download.staging").path
            )
        )
    }

    @Test func serverSessionDoesNotCacheResponsesOrStoreCookies() async throws {
        let configuration = ActualServerSyncClient.secureSessionConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)

        configuration.protocolClasses = [CredentialStorageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let host = "credential-storage-\(UUID().uuidString).example"
        let baseURL = try #require(URL(string: "https://\(host)"))
        let requestURL = baseURL.appending(path: "sync/list-user-files")
        var cacheRequest = URLRequest(url: requestURL)
        cacheRequest.httpMethod = "GET"
        URLCache.shared.removeCachedResponse(for: cacheRequest)
        defer { URLCache.shared.removeCachedResponse(for: cacheRequest) }

        let sharedCookieStorage = HTTPCookieStorage.shared
        for cookie in sharedCookieStorage.cookies(for: baseURL) ?? [] {
            sharedCookieStorage.deleteCookie(cookie)
        }

        let client = ActualServerSyncClient(baseURL: baseURL, session: session)
        let files = try await client.listUserFiles(token: "sensitive-token")

        #expect(files.isEmpty)
        #expect(URLCache.shared.cachedResponse(for: cacheRequest) == nil)
        #expect(sharedCookieStorage.cookies(for: baseURL)?.isEmpty != false)
    }

    @Test func serverSendsOnlyActualTokenCredentialHeader() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialHeaderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://credential-header.example")!,
            session: session
        )

        let files = try await client.listUserFiles(token: "sensitive-token")

        #expect(files.isEmpty)
    }

    @Test func serverBudgetDownloadStreamsToAFileAndRejectsOversizedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResourceLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let limits = testResourceLimits(maximumCompressedBudgetBytes: 8)
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDownload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let client = ActualServerSyncClient(
            baseURL: URL(string: "https://small-download.example")!,
            session: session,
            resourceLimits: limits
        )
        try await client.downloadUserFile(fileID: "file", token: "token", to: destinationURL)
        #expect(try Data(contentsOf: destinationURL) == Data("small".utf8))

        let oversizedClient = ActualServerSyncClient(
            baseURL: URL(string: "https://large-download.example")!,
            session: session,
            resourceLimits: limits
        )
        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try await oversizedClient.downloadUserFile(
                fileID: "file",
                token: "token",
                to: destinationURL
            )
        }

        let oversizedSyncClient = ActualServerSyncClient(
            baseURL: URL(string: "https://chunked-sync.example")!,
            session: session,
            resourceLimits: testResourceLimits(maximumSyncResponseBytes: 8)
        )
        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await oversizedSyncClient.sync(data: Data(), token: "token")
        }
    }

    @Test func syncClientRejectsOversizedTransportResponsesBeforeDecoding() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let client = SyncClient(
            resourceLimits: testResourceLimits(maximumSyncResponseBytes: 4)
        )
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "file",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: nil,
                encryptionContext: nil
            )
        )

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await client.pullAndApply(
                database: database,
                client: FixedResponseSyncTransport(responseData: Data(repeating: 0, count: 5)),
                token: "token"
            )
        }
    }

    @Test func budgetDatabaseMapsAccountsBalancesAndBudgetMonth() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let accounts = try await database.fetchAccountDisplays()
        let months = try await database.fetchAvailableMonths()
        let month = try await database.fetchBudgetMonth(month: "2026-07")

        #expect(accounts.map(\.account.id) == ["checking"])
        #expect(accounts.first?.balance == -12_345)
        #expect(months == ["2026-07"])
        #expect(month.totalBudgeted == 50_000)
        #expect(month.totalSpent == -12_345)
        #expect(month.totalBalance == 37_655)
        #expect(month.categoryGroups.first?.categories.first?.carryover == true)
    }

    @Test func budgetDatabaseCanonicalizesAvailableMonthValues() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO zero_budgets VALUES ('2026-8', 'groceries', 50000, 1);
            INSERT INTO transactions VALUES ('sept', 'checking', '2026/09/03', -12345, 'groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('invalid-month', 'checking', '2026-13-03', -12345, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        #expect(try await database.fetchAvailableMonths() == ["2026-07", "2026-08", "2026-09"])
    }

    @Test func budgetTemplateMessagesAppliesPriorityPeriodicWhenAvailable() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO category_groups VALUES ('income-group', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-group', 1, 0, 0, 0, NULL);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('salary-july', 'checking', 20260701, 100000, 'salary', 0, NULL, 0);
            INSERT INTO categories VALUES ('priority-food', 'Food', 'group', 0, 0, 0, 2, '[{"directive":"template","type":"periodic","amount":5,"period":{"period":"month","amount":1},"starting":"2026-07-01","priority":1}]');
            INSERT INTO category_mapping VALUES ('priority-food', 'priority-food');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("priority-food"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let month = try await database.fetchBudgetMonth(month: "2026-07")
        let food = try #require(month.categoryGroups.flatMap(\.categories).first { $0.id == "priority-food" })

        #expect(food.budgeted == 500)
    }

    @Test func budgetTemplateMonthlyUpToTopsUpAcrossMonths() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'buffer', 'Buffer', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('buffer', 'buffer');
            INSERT INTO zero_budgets VALUES (202606, 'buffer', 10000, 0);
            INSERT INTO zero_budgets VALUES (202607, 'buffer', 0, 0);
            INSERT INTO transactions VALUES ('buffer-june', 'checking', 20260610, -2000, 'buffer', 0, NULL, 0);
            INSERT INTO transactions VALUES ('buffer-july', 'checking', 20260710, -3000, 'buffer', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let julyMessages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(julyMessages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let julyBuffer = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )
        #expect(julyBuffer.budgeted == 2_000)
        #expect(julyBuffer.balance == 7_000)

        let augustMessages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(augustMessages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let augustBuffer = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )
        #expect(augustBuffer.budgeted == 3_000)
        #expect(augustBuffer.balance == 10_000)
    }

    @Test func budgetTemplateMonthlyUpToCanRefillOrReleaseExcess() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'refill', 'Refill', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"simple","monthly":null,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('refill', 'refill');
            INSERT INTO zero_budgets VALUES (202606, 'refill', 8000, 0);
            INSERT INTO categories VALUES (
                'release', 'Release', 'group', 0, 0, 0, 3,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('release', 'release');
            INSERT INTO zero_budgets VALUES (202606, 'release', 12000, 0);
            INSERT INTO categories VALUES (
                'hold', 'Hold', 'group', 0, 0, 0, 4,
                '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"monthly","hold":true,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('hold', 'hold');
            INSERT INTO zero_budgets VALUES (202606, 'hold', 12000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let refillMessages = try await database.budgetTemplateMessages(
            command: .category("refill"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(refillMessages)

        let releaseMessages = try await database.budgetTemplateMessages(
            command: .category("release"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(releaseMessages)

        let holdMessages = try await database.budgetTemplateMessages(
            command: .category("hold"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(holdMessages)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let categories = july.categoryGroups.flatMap(\.categories)
        #expect(categories.first { $0.id == "refill" }?.budgeted == 2_000)
        #expect(categories.first { $0.id == "release" }?.budgeted == -2_000)
        #expect(categories.first { $0.id == "hold" }?.budgeted == 0)
    }

    @Test func budgetTemplatePeriodicEveryTwoWeeksHonorsMonthlyUpTo() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'allowance', 'Allowance', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"periodic","amount":20,"period":{"period":"week","amount":2},"starting":"2026-06-20","limit":{"amount":30,"period":"monthly","hold":false,"start":null},"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('allowance', 'allowance');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("allowance"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let allowance = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "allowance" }
        )

        // July 4 and July 18 would total $40, so the monthly up-to caps it at $30.
        #expect(allowance.budgeted == 3_000)
    }

    @Test func budgetTemplateAncientDailyRecurrenceUsesBoundedArithmetic() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1},"starting":"0001-01-01","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("groceries"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 3_100)
    }

    @Test func budgetTemplateRejectsOutOfBoundsInputsBeforeTheyCanPersist() async throws {
        let invalidTemplates = [
            ("amount above maximum", #"{"directive":"template","type":"simple","monthly":1000000001,"priority":0}"#),
            ("negative amount", #"{"directive":"template","type":"simple","monthly":-1,"priority":0}"#),
            ("percentage above maximum", #"{"directive":"template","type":"simple","monthly":10,"percentage":101,"priority":0}"#),
            ("period interval above maximum", #"{"directive":"template","type":"periodic","amount":1,"period":{"period":"day","amount":1201},"starting":"2026-07-01","priority":0}"#),
            ("look-back above maximum", #"{"directive":"template","type":"copy","lookBack":1201,"priority":0}"#),
            ("repeat interval above maximum", #"{"directive":"template","type":"by","amount":10,"month":"2026-08","repeat":1201,"priority":0}"#),
            ("priority above maximum", #"{"directive":"template","type":"simple","monthly":10,"priority":1001}"#)
        ]

        for (label, template) in invalidTemplates {
            let fixtureURL = try makeSQLiteFixture(extraSQL: """
                ALTER TABLE categories ADD COLUMN goal_def TEXT;
                UPDATE categories
                SET goal_def = '[\(template)]'
                WHERE id = 'groceries';
                """)
            let database = try BudgetDatabase(databaseURL: fixtureURL)
            var builder = LocalFirstSyncMessageBuilder()

            do {
                _ = try await database.budgetTemplateMessages(
                    command: .category("groceries"),
                    month: "2026-07",
                    builder: &builder
                )
                Issue.record("Expected \(label) to be rejected")
            } catch LocalFirstError.unsupportedTemplate {
                // Expected: validation happens before any local CRDT write is constructed.
            } catch {
                Issue.record("Unexpected error for \(label): \(error)")
            }

            let july = try await database.fetchBudgetMonth(month: "2026-07")
            let groceries = try #require(
                july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
            )
            #expect(groceries.budgeted == 50_000, "Invalid case persisted: \(label)")
            #expect(try await database.pendingLocalSyncMessageCount() == 0)
        }
    }

    @Test func budgetTemplateRefusesUnprovenWeeklyUpToWithoutWriting() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"simple","monthly":50,"limit":{"amount":100,"period":"weekly","hold":false,"start":"2026-07-01"},"priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: LocalFirstError.self) {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
        }

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
    }

    @Test func budgetTemplateStandaloneMonthlyLimitAndRefillTopsUp() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'buffer', 'Buffer', 'group', 0, 0, 0, 2,
                '[
                    {"directive":"template","type":"limit","amount":100,"period":"monthly","hold":false,"start":null,"priority":0},
                    {"directive":"template","type":"refill","priority":0}
                ]'
            );
            INSERT INTO category_mapping VALUES ('buffer', 'buffer');
            INSERT INTO zero_budgets VALUES (202606, 'buffer', 8000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("buffer"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let buffer = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "buffer" }
        )

        #expect(buffer.budgeted == 2_000)
        #expect(buffer.balance == 10_000)
    }

    @Test func budgetTemplateBySpreadsRemainingTargetAcrossMonths() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'insurance', 'Insurance', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"by","amount":120,"month":"2026-09","priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('insurance', 'insurance');
            INSERT INTO zero_budgets VALUES (202606, 'insurance', 3000, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let julyMessages = try await database.budgetTemplateMessages(
            command: .category("insurance"),
            month: "2026-07",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(julyMessages)
        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let julyInsurance = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "insurance" }
        )
        #expect(julyInsurance.budgeted == 3_000)
        #expect(julyInsurance.balance == 6_000)

        let augustMessages = try await database.budgetTemplateMessages(
            command: .category("insurance"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(augustMessages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let augustInsurance = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "insurance" }
        )
        #expect(augustInsurance.budgeted == 3_000)
        #expect(augustInsurance.balance == 9_000)
    }

    @Test func budgetTemplateByAdvancesAnAnnualTarget() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            INSERT INTO categories VALUES (
                'renewal', 'Annual Renewal', 'group', 0, 0, 0, 2,
                '[{"directive":"template","type":"by","amount":120,"month":"2026-06","annual":true,"priority":0}]'
            );
            INSERT INTO category_mapping VALUES ('renewal', 'renewal');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        let messages = try await database.budgetTemplateMessages(
            command: .category("renewal"),
            month: "2026-08",
            builder: &builder
        )
        _ = try await database.applyLocalSyncMessages(messages)
        let august = try await database.fetchBudgetMonth(month: "2026-08")
        let renewal = try #require(
            august.categoryGroups.flatMap(\.categories).first { $0.id == "renewal" }
        )

        // The next June is 10 months away, so Actual spreads $120 over 11 months.
        #expect(renewal.budgeted == 1_091)
    }

    @Test func budgetTemplateDecodeFailureNamesCategoryAndFieldWithoutWriting() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories
            SET goal_def = '[{"directive":"template","type":"periodic","amount":50,"period":"month","priority":0}]'
            WHERE id = 'groceries';
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        var builder = LocalFirstSyncMessageBuilder()

        do {
            _ = try await database.budgetTemplateMessages(
                command: .category("groceries"),
                month: "2026-07",
                builder: &builder
            )
            Issue.record("Expected the malformed periodic template to be refused")
        } catch LocalFirstError.unsupportedTemplate(let reason) {
            #expect(reason.contains("Groceries"))
            #expect(reason.contains("template[0].period"))
            #expect(reason.localizedCaseInsensitiveContains("string"))
        }

        let july = try await database.fetchBudgetMonth(month: "2026-07")
        let groceries = try #require(
            july.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceries.budgeted == 50_000)
    }

    @Test func toBudgetIsCumulativeAcrossMonthsNotJustCurrentMonth() async throws {
        // June: assign 50000 to groceries, receive 200000 income, spend 40000 on groceries.
        // July: assign another 50000 to groceries (the fixture's -12345 July spend also applies).
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO zero_budgets VALUES (202606, 'groceries', 50000, 1);
            INSERT INTO transactions VALUES ('inc-jun', 'checking', 20260615, 200000, 'salary', 0, NULL, 0);
            INSERT INTO transactions VALUES ('gro-jun', 'checking', 20260620, -40000, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        // On-budget balance through July = 200000 - 40000 - 12345 = 147655.
        // Groceries balance carries June's 10000 leftover into July: 50000 - 12345 + 10000 = 47655.
        // To Budget = 147655 - 47655 = 100000 (i.e., total income 200000 - total budgeted 100000).
        // The old current-month-only formula would have reported 0 - 50000 = -50000.
        #expect(month.toBudget == 100_000)
    }

    @Test func toBudgetIgnoresUncategorizedActivityUntilCategorized() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('income', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            INSERT INTO transactions VALUES ('mystery', 'checking', 20260705, -1000, NULL, 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try await database.fetchBudgetMonth(month: "2026-07")

        // Uncategorized spending changes account balance, but Actual does not let it reduce
        // To Budget until it is assigned to a category.
        #expect(month.toBudget == 150_000)
    }

    @Test func budgetDatabaseUsesActualiSpendingSemanticsForMappedSplits() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            UPDATE zero_budgets SET amount = 0, carryover = 0 WHERE month = 202607 AND category = 'groceries';
            INSERT INTO category_mapping VALUES ('old-groceries', 'groceries');
            INSERT INTO zero_budgets VALUES (202608, 'groceries', 50000, 0);
            INSERT INTO transactions VALUES ('mapped', 'checking', 20260803, -10000, 'old-groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('split-parent', 'checking', 20260804, -30000, 'groceries', 0, NULL, 1);
            INSERT INTO transactions VALUES ('split-child-1', 'checking', 20260804, -20000, 'groceries', 0, 'split-parent', 0);
            INSERT INTO transactions VALUES ('split-child-2', 'checking', 20260804, -10000, 'groceries', 0, 'split-parent', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let month = try await database.fetchBudgetMonth(month: "2026-08")
        let groceries = month.categoryGroups.first?.categories.first

        #expect(groceries?.budgeted == 50_000)
        #expect(groceries?.spent == -40_000)
        #expect(groceries?.balance == 10_000)
    }

    @Test func localFirstSyncValueSerializesActualWireValues() async {
        #expect(LocalFirstSyncValue.null.serialized == "0:")
        #expect(LocalFirstSyncValue.int(42).serialized == "N:42")
        #expect(LocalFirstSyncValue.double(12.5).serialized == "N:12.5")
        #expect(LocalFirstSyncValue.string("Coffee").serialized == "S:Coffee")
        #expect(LocalFirstSyncValue.bool(true).serialized == "N:1")
        #expect(LocalFirstSyncValue.bool(false).serialized == "N:0")
    }

    @Test func hybridLogicalClockUsesNodeIDAndIncrementsWhenWallClockDoesNotAdvance() async throws {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )

        let first = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        let second = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        let advanced = try clock.next(now: Date(timeIntervalSince1970: 2.0))

        #expect(first == "1970-01-01T00:00:01.234Z-0001-node1")
        #expect(second == "1970-01-01T00:00:01.234Z-0002-node1")
        #expect(advanced == "1970-01-01T00:00:02.000Z-0000-node1")
    }

    @Test func hybridLogicalClockThrowsWhenCounterOverflows() async {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-ffff-node1"
        )

        #expect(throws: LocalFirstError.hybridLogicalClockOverflow) {
            _ = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        }
    }

    @Test func hybridLogicalClockUsesActualClientIDShape() async {
        let uuid = UUID(uuidString: "A219E7A7-1CC1-8912-ABCD-0123456789AB")!

        #expect(HybridLogicalClock.makeClientID(uuid: uuid) == "abcd0123456789ab")
        #expect(HybridLogicalClock.normalizedNodeID("node-1") == "node1")
    }

    @Test func concurrentLocalMutationsMintDistinctMonotonicTimestampsAfterSuspending() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let mutationCount = 128
        let fixedNow = Date(timeIntervalSince1970: 1_783_404_000)

        let appliedCount = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<mutationCount {
                group.addTask {
                    // Force every operation to cross a suspension point before contending for the
                    // database actor. The old MAX(timestamp)-derived clocks then shared a seed.
                    await Task.yield()
                    let draft = ActualSyncDecodedMessage(
                        timestamp: String(format: "actualist-pending-%08x", index),
                        dataset: "transactions",
                        row: "txn",
                        column: "category",
                        serializedValue: LocalFirstSyncValue.string("category-\(index)").serialized
                    )
                    return try await database.commitLocalSyncMessagesAndEnqueue(
                        [draft],
                        now: fixedNow
                    )
                }
            }

            var total = 0
            for try await count in group {
                total += count
            }
            return total
        }

        let timestamps = try await database.pendingLocalSyncMessages().map(\.message.timestamp)
        #expect(appliedCount == mutationCount)
        #expect(timestamps.count == mutationCount)
        #expect(Set(timestamps).count == mutationCount)
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.first?.contains("-0000-node1") == true)
        #expect(timestamps.last?.contains("-007f-node1") == true)
    }

    @Test func concurrentStoreMutationsAcrossActorSuspensionAllReachTheOutbox() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let mutationCount = 32

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<mutationCount {
                group.addTask {
                    await Task.yield()
                    _ = try await bundle.store.assignCategoryBudgetAndRefresh(
                        categoryID: "groceries",
                        budgeted: 60_000 + index,
                        budgetID: "group-1",
                        month: "2026-07"
                    ) {}
                }
            }
            try await group.waitForAll()
        }

        let database = try #require(bundle.store.database)
        let pending = try await database.pendingLocalSyncMessages()
        let timestamps = pending.map(\.message.timestamp)
        // Budget assignments carry month/category identity plus amount.
        let expectedMessageCount = mutationCount * 3
        #expect(pending.count == expectedMessageCount)
        #expect(Set(timestamps).count == expectedMessageCount)
        #expect(timestamps == timestamps.sorted())
    }

    @Test func localClockResumesFromPersistedTimestampAcrossDatabaseLifecycles() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let fixedNow = Date(timeIntervalSince1970: 1_783_404_000)
        var database: BudgetDatabase? = try BudgetDatabase(
            databaseURL: fixtureURL,
            localNodeID: "node1"
        )
        let firstDraft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("first").serialized
        )

        _ = try await database?.commitLocalSyncMessagesAndEnqueue([firstDraft], now: fixedNow)
        database = nil

        let reopened = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let secondDraft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("second").serialized
        )
        _ = try await reopened.commitLocalSyncMessagesAndEnqueue([secondDraft], now: fixedNow)

        let timestamps = try await reopened.pendingLocalSyncMessages().map(\.message.timestamp)
        #expect(timestamps.count == 2)
        #expect(timestamps[0].contains("-0000-node1"))
        #expect(timestamps[1].contains("-0001-node1"))
    }

    @Test func remoteTimestampAdvancesLoadedLocalClockWithoutStorageReseed() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let remote = ActualSyncDecodedMessage(
            timestamp: "2026-07-25T12:00:00.000Z-000a-remote",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("remote").serialized
        )
        _ = try await database.applyRemoteSyncMessages([remote])

        let draft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("local").serialized
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            [draft],
            now: Date(timeIntervalSince1970: 0)
        )

        let localTimestamp = try #require(
            await database.pendingLocalSyncMessages().first?.message.timestamp
        )
        #expect(localTimestamp == "2026-07-25T12:00:00.000Z-000b-node1")
    }

    @Test func remoteApplyReportsOnlyNewLiveTopLevelTransactions() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let messages = [
            remoteMessage(index: 0, row: "new-top", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "new-top", column: "amount", value: .int(-2_500)),
            remoteMessage(index: 2, row: "txn", column: "amount", value: .int(-13_000)),
            remoteMessage(index: 3, row: "new-child", column: "acct", value: .string("checking")),
            remoteMessage(index: 4, row: "new-child", column: "parent_id", value: .string("new-top")),
            remoteMessage(index: 5, row: "new-deleted", column: "acct", value: .string("checking")),
            remoteMessage(index: 6, row: "new-deleted", column: "tombstone", value: .bool(true)),
            remoteMessage(index: 7, row: "new-split-parent", column: "acct", value: .string("checking")),
            remoteMessage(index: 8, row: "new-split-parent", column: "is_parent", value: .bool(true))
        ]

        let result = try await database.applyRemoteSyncMessagesTrackingInserts(messages)

        #expect(result.appliedMessageCount == messages.count)
        #expect(
            result.insertedTransactionIDsByAccount
                == ["checking": ["new-split-parent", "new-top"]]
        )

        let updateResult = try await database.applyRemoteSyncMessagesTrackingInserts([
            remoteMessage(index: 9, row: "new-top", column: "amount", value: .int(-3_000))
        ])
        #expect(updateResult.insertedTransactionIDsByAccount.isEmpty)
    }

    @Test func backgroundSyncUsesAppliedInsertIDsWithoutSnapshotDiffing() async throws {
        let transport = RecordingSyncTransport()
        try await transport.seedServerMessages([
            remoteMessage(index: 0, row: "background-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "background-new", column: "amount", value: .int(-4_200)),
            remoteMessage(index: 2, row: "txn", column: "amount", value: .int(-13_000))
        ])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("token")

        let results = try await bundle.store.syncAndFindNewTransactions(
            budget: bundle.budget,
            serverURLString: "https://sync.example"
        )

        #expect(results.count == 1)
        #expect(results.first?.account.id == "checking")
        #expect(results.first?.newTransactionIDs == ["background-new"])
    }

    @Test func backgroundRefreshTimeLimitRecordsCleanCompletion() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 5_000_000_000)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true
        state.setupPhase = .ready
        state.selectedBudget = bundle.budget

        let success = await state.performBackgroundTransactionRefresh(
            timeLimit: .milliseconds(10)
        )

        #expect(!success)
        let run = try #require(state.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.completionDate != nil)
        #expect(run.succeeded == false)
        #expect(run.message == "Timed out")
    }

    @Test func localFirstSyncMessageEnvelopeRoundTripsThroughProtobuf() async throws {
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: "S:groceries"
        )

        let envelope = try LocalFirstSyncMessageBuilder.envelope(for: message)
        let decoded = try ActualSync_Message(serializedBytes: envelope.content)

        #expect(envelope.timestamp == message.timestamp)
        #expect(envelope.isEncrypted == false)
        #expect(decoded.dataset == "transactions")
        #expect(decoded.row == "txn")
        #expect(decoded.column == "category")
        #expect(decoded.value == "S:groceries")
    }

    @Test func encryptedDataDecodesActualWireFieldOrder() async throws {
        let iv = Data("123456789012".utf8)
        let authTag = Data("abcdefghijklmnop".utf8)
        let data = Data("ciphertext".utf8)
        var wireData = Data()
        wireData.append(contentsOf: [0x0a, UInt8(iv.count)])
        wireData.append(iv)
        wireData.append(contentsOf: [0x12, UInt8(authTag.count)])
        wireData.append(authTag)
        wireData.append(contentsOf: [0x1a, UInt8(data.count)])
        wireData.append(data)

        let encryptedData = try ActualSync_EncryptedData(serializedBytes: wireData)

        #expect(encryptedData.iv == iv)
        #expect(encryptedData.authTag == authTag)
        #expect(encryptedData.data == data)
    }

    @Test func localFirstSyncMessageEnvelopeCanBeEncrypted() async throws {
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: "S:groceries"
        )

        let envelope = try LocalFirstSyncMessageBuilder.envelope(
            for: message,
            encryptionContext: context
        )
        let encryptedData = try ActualSync_EncryptedData(serializedBytes: envelope.content)
        let decrypted = try ActualBudgetCrypto.decrypt(
            ActualEncryptedData(
                data: encryptedData.data,
                iv: encryptedData.iv,
                authTag: encryptedData.authTag
            ),
            keyData: context.keyData
        )
        let decoded = try ActualSync_Message(serializedBytes: decrypted)

        #expect(envelope.timestamp == message.timestamp)
        #expect(envelope.isEncrypted)
        #expect(decoded.dataset == "transactions")
        #expect(decoded.row == "txn")
        #expect(decoded.column == "category")
        #expect(decoded.value == "S:groceries")
    }

    @Test func encryptedBudgetLogsAndAllowsMixedPlaintextEnvelopesByDefault() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let encryptedMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-server",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("utilities").serialized
        )
        let plaintextMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0001-server",
            dataset: "transactions",
            row: "txn",
            column: "amount",
            serializedValue: LocalFirstSyncValue.int(-9_999).serialized
        )
        var response = ActualSync_SyncResponse()
        response.messages = [
            try LocalFirstSyncMessageBuilder.envelope(
                for: encryptedMessage,
                encryptionContext: context
            ),
            try LocalFirstSyncMessageBuilder.envelope(for: plaintextMessage)
        ]
        let recorder = PlaintextEnvelopeAuditRecorder()
        let client = SyncClient(plaintextEnvelopeAuditRecorder: recorder.record)
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "private-budget-id",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: context.keyID,
                encryptionContext: context
            )
        )

        let result = try await client.pullAndApply(
            database: database,
            client: FixedResponseSyncTransport(responseData: try response.serializedData()),
            token: "token"
        )

        let transaction = try #require(
            try await database.fetchTransactions(accountID: "checking")
                .first { $0.id == "txn" }
        )
        let events = recorder.events()
        let event = try #require(events.first)
        #expect(result.appliedMessageCount == 2)
        #expect(transaction.category == "utilities")
        #expect(transaction.amount == -9_999)
        #expect(event.budgetIDHash != "private-budget-id")
        #expect(event.budgetIDHash.count == 64)
        #expect(event.plaintextMessageCount == 1)
        #expect(event.totalMessageCount == 2)
        #expect(event.earliestTimestamp == plaintextMessage.timestamp)
        #expect(event.latestTimestamp == plaintextMessage.timestamp)
        #expect(event.hasEncryptionContext)
        #expect(events.count == 1)
    }

    @Test func encryptedBudgetCanRejectMixedPlaintextEnvelopesWithoutApplyingAny() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let encryptedMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-server",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("utilities").serialized
        )
        let plaintextMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0001-server",
            dataset: "transactions",
            row: "txn",
            column: "amount",
            serializedValue: LocalFirstSyncValue.int(-9_999).serialized
        )
        var response = ActualSync_SyncResponse()
        response.messages = [
            try LocalFirstSyncMessageBuilder.envelope(
                for: encryptedMessage,
                encryptionContext: context
            ),
            try LocalFirstSyncMessageBuilder.envelope(for: plaintextMessage)
        ]
        let recorder = PlaintextEnvelopeAuditRecorder()
        let client = SyncClient(
            enforcesAuthenticatedEncryptedEnvelopes: true,
            plaintextEnvelopeAuditRecorder: recorder.record
        )
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "private-budget-id",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: context.keyID,
                encryptionContext: context
            )
        )

        await #expect(throws: LocalFirstError.unauthenticatedPlaintextEnvelope) {
            _ = try await client.pullAndApply(
                database: database,
                client: FixedResponseSyncTransport(responseData: try response.serializedData()),
                token: "token"
            )
        }

        let transaction = try #require(
            try await database.fetchTransactions(accountID: "checking")
                .first { $0.id == "txn" }
        )
        #expect(transaction.category == "groceries")
        #expect(transaction.amount == -12_345)
        #expect(recorder.events().count == 1)
    }

    @Test func applyLocalSyncMessagesUpdatesSQLiteAndMessagesTable() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("gas").serialized
        )

        let appliedCount = try await database.applyLocalSyncMessages([message])

        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })
        #expect(appliedCount == 1)
        #expect(transaction.category == "gas")
        #expect(try await database.latestSyncTimestamp() == message.timestamp)
    }

    @Test func sameCellLocalTimestampCollisionIsReportedAndDoesNotChangeTheValue() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let timestamp = "2026-07-04T12:34:56.789Z-0000-node1"
        let first = ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("first").serialized
        )
        let colliding = ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("silently-lost-before-8a").serialized
        )

        _ = try await database.applyLocalSyncMessages([first])
        await #expect(throws: LocalFirstError.localWriteSuperseded) {
            _ = try await database.applyLocalSyncMessages([colliding])
        }

        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })
        #expect(transaction.category == "first")
        #expect(try await database.latestSyncTimestamp() == timestamp)
    }

    @Test func midBatchRollbackKeepsDatabaseAndVisibleBudgetStateInSyncAndShowsError() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                CREATE TRIGGER fail_budget_amount_message
                BEFORE INSERT ON messages_crdt
                WHEN NEW.dataset = 'zero_budgets' AND NEW.column = 'amount'
                BEGIN
                    SELECT RAISE(ABORT, 'forced mid-batch failure');
                END;
                """
        )
        let model = BudgetViewModel()
        await model.load(budgetID: "group-1", repository: bundle.store)
        let initialCategory = try #require(
            model.visibleGroups.flatMap(\.visibleCategories).first { $0.id == "groceries" }
        )
        #expect(initialCategory.budgeted == 50_000)

        model.beginAssignmentEditing(for: initialCategory)
        for digit in [6, 0, 0, 0, 0] {
            model.appendAssignmentDigit(digit)
        }
        let saved = await model.submitAssignment(
            budgetID: "group-1",
            repository: bundle.store
        )

        #expect(!saved)
        #expect(
            model.activeAssignmentErrorMessage
                == LocalFirstError.invalidLocalWrite(
                    "the database transaction was rolled back"
                ).localizedDescription
        )
        #expect(model.assignmentDraft?.submissionState.isSubmitting == false)
        #expect(
            model.visibleGroups.flatMap(\.visibleCategories)
                .first { $0.id == "groceries" }?.budgeted == 50_000
        )

        let reloaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let persistedCategory = try #require(
            reloaded.month.categoryGroups.flatMap(\.categories)
                .first { $0.id == "groceries" }
        )
        #expect(persistedCategory.budgeted == 50_000)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
    }

    @Test func applyLocalSyncMessagesAndEnqueueStoresPendingOutboxMessages() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        // Match a real imported budget: status/refresh probes the optional outbox before the
        // first write creates it. This used to cache `false` permanently for the DB session.
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        let baseTimestamp = try await database.latestSyncTimestamp()
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("gas").serialized
        )

        let appliedCount = try await database.applyLocalSyncMessagesAndEnqueue([message], baseTimestamp: baseTimestamp)
        let pending = try await database.pendingLocalSyncMessages()
        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })

        #expect(appliedCount == 1)
        #expect(transaction.category == "gas")
        #expect(pending.map(\.message) == [message])
        #expect(pending.first?.baseTimestamp == baseTimestamp)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
    }

    @Test func failedLocalSyncApplyDoesNotLeaveOutboxRows() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "bogus",
            serializedValue: LocalFirstSyncValue.string("nope").serialized
        )

        await #expect(throws: LocalFirstError.invalidLocalWrite("unknown column transactions.bogus")) {
            _ = try await database.applyLocalSyncMessagesAndEnqueue(
                [message],
                baseTimestamp: try await database.latestSyncTimestamp()
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func applyLocalSyncMessagesRejectsUnknownColumns() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "bogus",
            serializedValue: LocalFirstSyncValue.string("nope").serialized
        )

        await #expect(throws: LocalFirstError.invalidLocalWrite("unknown column transactions.bogus")) {
            _ = try await database.applyLocalSyncMessages([message])
        }
    }

    @Test func deserializeRemoteNumericPayloadsRejectNonFiniteButPreservesHugeDoubles() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let huge = try await database.deserializeSyncValue("N:1e300")
        switch huge {
        case .double(let value):
            #expect(value == 1e300)
        default:
            Issue.record("Expected 1e300 to decode as a Double")
        }

        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            _ = try await database.deserializeSyncValue("N:inf")
        }
        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            _ = try await database.deserializeSyncValue("N:not-a-number")
        }
    }

    @Test func remoteUnknownDatasetOrColumnAdvancesSyncWithoutMutatingLocalTables() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let unknownDataset = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "future_table",
            row: "row-1",
            column: "name",
            serializedValue: LocalFirstSyncValue.string("ignored").serialized
        )
        let unknownColumn = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:57.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "future_column",
            serializedValue: LocalFirstSyncValue.string("ignored").serialized
        )

        let appliedCount = try await database.applyRemoteSyncMessages([unknownColumn, unknownDataset])
        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })

        #expect(appliedCount == 2)
        #expect(transaction.category == "groceries")
        #expect(try await database.latestSyncTimestamp() == unknownColumn.timestamp)
    }

    @Test func refreshWithoutOpenBudgetThrowsBudgetNotOpened() async {
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refresh(budgetID: "missing", serverURLString: "https://example.com")
        }
    }

    @Test func refreshLocalFirstDataIsNoOpWithoutOpenBudget() async {
        let state = makeAppState()
        state.setupPhase = .ready
        state.connectionStatus = .online

        // No budget has been opened, so the guard returns immediately without mutating state.
        await state.refreshLocalFirstData(budgetID: "any")

        #expect(state.connectionStatus == .online)
        #expect(state.localFirstSyncStatus == nil)
    }

    @Test(arguments: ReimportFailureScenario.allCases)
    func reimportFailureLeavesOriginalBudgetOpen(
        scenario: ReimportFailureScenario
    ) async throws {
        let archiveData: Data
        switch scenario {
        case .corruptArchive:
            archiveData = Data("not a zip archive".utf8)
        case .wrongSchema:
            let wrongSchemaURL = FileManager.default.temporaryDirectory
                .appending(path: "ActualistWrongSchema-\(UUID().uuidString).sqlite")
            let queue = try DatabaseQueue(path: wrongSchemaURL.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
            }
            archiveData = try makeArchiveData(databaseURL: wrongSchemaURL)
        default:
            archiveData = try makeArchiveData(databaseURL: makeSQLiteFixture())
        }

        let failurePoint: StubConnectionTransport.FailurePoint =
            scenario == .midDownload ? .download : .none
        let injectedCheckpoint: BudgetReimportCheckpoint?
        switch scenario {
        case .midDecrypt:
            injectedCheckpoint = .beforeDecrypt
        case .midExtract:
            injectedCheckpoint = .beforeExtract
        default:
            injectedCheckpoint = nil
        }

        let connectionTransport = StubConnectionTransport(
            failurePoint: failurePoint,
            files: [testRemoteFile()],
            token: "reimport-token",
            downloadData: archiveData
        )
        let syncTransport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport },
            reimportFailureCheckpoint: injectedCheckpoint
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")
        let original = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )

        await #expect(throws: (any Error).self) {
            try await bundle.store.reimportBudget(
                bundle.budget,
                serverURLString: "https://sync.example"
            )
        }

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let restored = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(restored.month == original.month)
        #expect(try Data(contentsOf: bundle.fileManager.databaseURL(fileID: "file-1")).count > 0)
        let budgetRoot = bundle.fileManager.applicationSupportURL.appending(path: "Budgets")
        let leftoverNames = try FileManager.default.contentsOfDirectory(atPath: budgetRoot.path)
        #expect(!leftoverNames.contains { $0.contains(".reimport-") })
    }

    @Test func successfulReimportOpensReplacementAndRetainsRecoverableBackup() async throws {
        let replacementURL = try makeSQLiteFixture(
            extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
        )
        let archiveData = try makeArchiveData(databaseURL: replacementURL)
        let connectionTransport = StubConnectionTransport(
            files: [testRemoteFile()],
            token: "reimport-token",
            downloadData: archiveData
        )
        let syncTransport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport }
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")

        try await bundle.store.reimportBudget(
            bundle.budget,
            serverURLString: "https://sync.example"
        )

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let accounts = bundle.store.accountDisplays(budgetID: "group-1").map(\.account.id)
        #expect(accounts.contains("replacement"))
        #expect(try bundle.fileManager.reimportBackupExists(fileID: "file-1"))
    }

    @Test(arguments: [
        ("http://actual.example.com", StubConnectionTransport.FailurePoint.none, false),
        ("https://unreachable.example", .loginMethods, false),
        ("https://wrong-password.example", .login, false),
        ("https://empty.example", .none, true)
    ])
    func failedConnectionValidationPreservesWorkingConnection(
        attemptedURL: String,
        failurePoint: StubConnectionTransport.FailurePoint,
        returnsNoBudgets: Bool
    ) async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        let previousSettings = AppSettings(
            localFirstServerURLString: "https://working.example",
            selectedBudgetID: "group-old",
            selectedBudgetName: "Working Budget",
            selectedLocalFirstFileID: "file-old",
            selectedLocalFirstGroupID: "group-old",
            backgroundTransactionRefreshEnabled: true,
            pendingNewTransactionIDsByAccount: ["group-old:checking": ["txn-old"]]
        )
        settingsStore.save(previousSettings)

        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: backend
        )
        try keychain.saveActualSyncToken("working-token")
        try keychain.saveLocalFirstEncryptionKey(
            Data("working-key".utf8),
            fileID: "file-old",
            keyID: "key-old"
        )

        let connectionTransport = StubConnectionTransport(
            failurePoint: failurePoint,
            files: returnsNoBudgets ? [] : [
                ActualSyncRemoteFile(
                    fileID: "file-new",
                    groupID: "group-new",
                    name: "New Budget"
                )
            ]
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            connectionTransportFactory: { _ in connectionTransport }
        )
        let state = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            localFirstStore: store
        )
        state.setupPhase = .ready
        state.connectionStatus = .online
        let model = SettingsViewModel()
        model.actualPassword = "attempted-password"
        model.serverURLString = attemptedURL

        await model.saveAndTest(using: state)

        #expect(state.settings == previousSettings)
        #expect(settingsStore.load() == previousSettings)
        #expect(keychain.readActualSyncToken() == "working-token")
        #expect(
            keychain.readLocalFirstEncryptionKey(fileID: "file-old", keyID: "key-old")
                == Data("working-key".utf8)
        )
        #expect(state.setupPhase == .ready)
        #expect(state.connectionStatus == .online)
        #expect(model.actualPassword == "attempted-password")
    }

    @Test func syncStatusDefaultsAndEquality() async {
        let base = LocalFirstSyncStatus(fileID: "file", groupID: "group")
        #expect(base.lastSyncedAt == nil)
        #expect(base.lastAppliedMessageCount == 0)
        #expect(base.lastError == nil)
        #expect(base == LocalFirstSyncStatus(fileID: "file", groupID: "group"))
        #expect(base != LocalFirstSyncStatus(fileID: "file", groupID: "other"))
    }

    private func makeAppState() -> AppState {
        let defaultsName = "ActualistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )
    }

    @Test func accountFeedExcludesTombstonedAndAttachesSplits() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions VALUES ('dead', 'checking', 20260702, -999, 'groceries', 1, NULL, 0);
            INSERT INTO transactions VALUES ('split', 'checking', 20260701, -5000, NULL, 0, NULL, 1);
            INSERT INTO transactions VALUES ('split-a', 'checking', 20260701, -2000, 'groceries', 0, 'split', 0);
            INSERT INTO transactions VALUES ('split-b', 'checking', 20260701, -3000, 'groceries', 0, 'split', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let transactions = try await database.fetchTransactions(accountID: "checking")
        let ids = transactions.compactMap(\.id)

        #expect(!ids.contains("dead"))     // tombstoned excluded
        #expect(!ids.contains("split-a"))  // split children are not top-level rows
        #expect(ids.contains("txn"))
        #expect(ids.contains("split"))

        let split = transactions.first { $0.id == "split" }
        #expect(split?.subtransactions.count == 2)
        #expect(Set(split?.subtransactions.compactMap(\.id) ?? []) == ["split-a", "split-b"])

        let txn = transactions.first { $0.id == "txn" }
        #expect(txn?.date == "2026-07-03")
        #expect(txn?.amount == -12345)
        #expect(txn?.category == "groceries")
    }

    @Test func spendingFeedSpansAccountsAndSearchFilters() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            INSERT INTO transactions VALUES ('txn2', 'savings', 20260704, -55500, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let all = try await database.fetchTransactions()
        #expect(Set(all.compactMap(\.id)) == ["txn", "txn2"])

        let search = try await database.fetchTransactions(matching: "55500")
        #expect(search.compactMap(\.id) == ["txn2"])
    }

    @Test func transactionPageLimitsTopLevelRowsAndKeepsSplitChildren() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions VALUES ('older-a', 'checking', 20260702, -1000, 'groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('older-b', 'checking', 20260701, -1000, 'groceries', 0, NULL, 0);
            INSERT INTO transactions VALUES ('split', 'checking', 20260706, -3000, NULL, 0, NULL, 1);
            INSERT INTO transactions VALUES ('split-a', 'checking', 20260706, -1000, 'groceries', 0, 'split', 0);
            INSERT INTO transactions VALUES ('split-b', 'checking', 20260706, -2000, 'groceries', 0, 'split', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let firstPage = try await database.fetchTransactionPage(accountID: "checking", limit: 2)
        let secondPage = try await database.fetchTransactionPage(accountID: "checking", limit: 2, offset: 2)

        #expect(firstPage.transactions.compactMap(\.id) == ["split", "txn"])
        #expect(firstPage.transactions.first?.subtransactions.count == 2)
        #expect(!firstPage.reachedEnd)
        #expect(secondPage.transactions.compactMap(\.id) == ["older-a", "older-b"])
        #expect(secondPage.reachedEnd)
    }

    @Test func localFirstTransactionFeedsLoadInitialPageThenOlderRows() async throws {
        let bulkSQL = (0..<105).map { index in
            "INSERT INTO transactions VALUES ('bulk-\(String(format: "%03d", index))', 'checking', 20260701, -1000, 'groceries', 0, NULL, 0);"
        }.joined(separator: "\n")
        let fixtureURL = try makeSQLiteFixture(extraSQL: bulkSQL)
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let store = makeStore()
        store.openedBudgetID = "group-1"
        store.database = database
        store.accountsByBudget["group-1"] = try await database.fetchAccountDisplays()

        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        let firstPage = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))

        #expect(firstPage.transactions.count == 100)
        #expect(!firstPage.reachedEnd)

        try await store.loadOlderTransactions(budgetID: "group-1", accountID: "checking")
        let fullWindow = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))

        #expect(fullWindow.transactions.count == 106)
        #expect(fullWindow.reachedEnd)
    }

    @Test func transactionSearchTreatsPercentAndUnderscoreAsLiteralCharacters() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            UPDATE transactions SET notes = 'plain note' WHERE id = 'txn';
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, notes)
                VALUES ('percent', 'checking', 20260704, -1000, 'groceries', 0, NULL, 0, '100% real');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, notes)
                VALUES ('underscore', 'checking', 20260705, -1000, 'groceries', 0, NULL, 0, 'under_score');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let percent = try await database.fetchTransactions(matching: "%")
        let underscore = try await database.fetchTransactions(matching: "_")

        #expect(percent.compactMap(\.id) == ["percent"])
        #expect(underscore.compactMap(\.id) == ["underscore"])
    }

    @Test func accountFeedResolvesPayeeThroughPayeeMapping() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            INSERT INTO payees VALUES ('amazon', 'Amazon', NULL, 0);
            INSERT INTO payee_mapping VALUES ('amazon', 'amazon');
            INSERT INTO payee_mapping VALUES ('amazon-src', 'amazon');
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description)
                VALUES ('amz', 'checking', 20260705, -2500, 'groceries', 0, NULL, 0, 'amazon-src');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let amazon = try await database.fetchTransactions(accountID: "checking").first { $0.id == "amz" }
        // The payee id lives in `description`; `amazon-src` remaps to the canonical `amazon` payee.
        #expect(amazon?.payee == "amazon")
        #expect(amazon?.payeeName == "Amazon")
    }

    @Test func feedResolvesTransferPayeeToAccountName() async throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('xfer', '', 'savings', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description)
                VALUES ('t-xfer', 'checking', 20260706, -10000, NULL, 0, NULL, 0, 'xfer');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let transfer = try await database.fetchTransactions(accountID: "checking").first { $0.id == "t-xfer" }
        // Transfer payee has an empty name; the feed shows the linked account's name.
        #expect(transfer?.payeeName == "Savings")
    }

    @Test func refreshAccountTransactionsWithoutOpenBudgetThrows() async {
        let store = makeStore()
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refreshAccountTransactions(budgetID: "b", accountID: "a")
        }
    }

    @Test func deleteTransactionWithoutOpenBudgetThrows() async {
        let store = makeStore()
        let transaction = ActualTransaction(
            id: "x", account: "a", date: "2026-07-03", amount: -1,
            payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil, cleared: nil
        )
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await store.deleteTransactionAndRefresh(transaction, budgetID: "b") {}
        }
    }

    @Test func uncategorizedAlertCountsOnlyReviewableTransactions() async {
        let transferAccountIDsByPayeeID = ["on-budget-xfer": "checking"]
        let transactions = [
            makeTransaction(id: "needs-category", category: nil),
            makeTransaction(id: "also-needs", category: ""),
            makeTransaction(id: "categorized", category: "groceries"),
            makeTransaction(id: "transfer", category: nil, payee: "on-budget-xfer"),
            makeTransaction(id: "split-parent", category: nil, isParent: true),
            makeTransaction(id: "other-month", category: nil, date: "2026-06-30"),
            makeTransaction(
                id: "split-with-children",
                category: nil,
                subtransactions: [makeTransaction(id: "child", category: "groceries")]
            )
        ]

        let alerts = LocalFirstActualStore.uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: [],
            month: "2026-07"
        )

        #expect(alerts.count == 1)
        let alert = try! #require(alerts.first)
        #expect(alert.kind == "uncategorizedTransactions")
        #expect(alert.severity == "warning")
        #expect(alert.title == "Uncategorized transactions")
        #expect(alert.actionTitle == "Review")
        #expect(alert.count == 2)
    }

    @Test func uncategorizedAlertEmptyWhenEverythingCategorized() async {
        let transactions = [
            makeTransaction(id: "a", category: "groceries"),
            makeTransaction(id: "b", category: "rent")
        ]

        let alerts = LocalFirstActualStore.uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: [:],
            offBudgetAccountIDs: [],
            month: "2026-07"
        )

        #expect(alerts.isEmpty)
    }

    @Test func uncategorizedAlertIncludesOnBudgetTransferToOffBudgetAccount() async {
        let transactions = [
            makeTransaction(id: "off-budget-transfer", category: nil, payee: "off-budget-xfer"),
            makeTransaction(id: "on-budget-transfer", category: nil, payee: "on-budget-xfer")
        ]

        let alerts = LocalFirstActualStore.uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: [
                "off-budget-xfer": "savings",
                "on-budget-xfer": "checking"
            ],
            offBudgetAccountIDs: ["savings"],
            month: "2026-07"
        )

        #expect(alerts.first?.count == 1)
    }

    @Test func uncategorizedAlertExcludesTransactionsInsideOffBudgetAccounts() async {
        let transactions = [
            makeTransaction(id: "tracking-adjustment", account: "tracking", category: nil),
            makeTransaction(id: "checking-purchase", account: "checking", category: nil)
        ]

        let alerts = LocalFirstActualStore.uncategorizedAlerts(
            transactions: transactions,
            transferAccountIDsByPayeeID: [:],
            offBudgetAccountIDs: ["tracking"],
            month: "2026-07"
        )

        #expect(alerts.first?.count == 1)
    }

    @Test func toBudgetAlertShowsSurplusAndOverbudgetButNotZero() async {
        let surplus = try! #require(LocalFirstActualStore.toBudgetAlert(month: makeBudgetMonth(toBudget: 1500)))
        #expect(surplus.kind == "toBudget")
        #expect(surplus.severity == "positive")
        #expect(surplus.title == "To Budget")
        #expect(surplus.amount == 1500)
        #expect(surplus.actionTitle == nil)

        // Actual allows a negative "To Budget" (overbudgeted); it must still be shown, signed.
        let overbudgeted = try! #require(LocalFirstActualStore.toBudgetAlert(month: makeBudgetMonth(toBudget: -500)))
        #expect(overbudgeted.severity == "warning")
        #expect(overbudgeted.amount == -500)

        #expect(LocalFirstActualStore.toBudgetAlert(month: makeBudgetMonth(toBudget: 0)) == nil)
    }

    @Test func overspendingAlertCountsVisibleNegativeCategoriesInSpendingGroups() async {
        let month = makeBudgetMonth(
            toBudget: 0,
            groups: [
                makeGroup(id: "everyday", isIncome: false, categories: [
                    makeCategory(id: "groceries", balance: -2000),
                    makeCategory(id: "rent", balance: 500),
                    makeCategory(id: "hidden-over", balance: -100, hidden: true)
                ]),
                // Income groups and their categories never count as overspending.
                makeGroup(id: "income", isIncome: true, categories: [
                    makeCategory(id: "paycheck", balance: -9999)
                ])
            ]
        )

        let alert = try! #require(LocalFirstActualStore.overspendingAlert(month: month))
        #expect(alert.kind == "overspending")
        #expect(alert.severity == "danger")
        #expect(alert.title == "Overspent categories")
        #expect(alert.actionTitle == "Cover")
        #expect(alert.count == 1)
    }

    @Test func budgetAlertsAreOrderedToBudgetThenOverspendingThenUncategorized() async {
        let month = makeBudgetMonth(
            toBudget: 1500,
            groups: [
                makeGroup(id: "everyday", isIncome: false, categories: [
                    makeCategory(id: "groceries", balance: -2000)
                ])
            ]
        )
        let transactions = [makeTransaction(id: "needs-category", category: nil)]

        let alerts = LocalFirstActualStore.budgetAlerts(
            month: month,
            monthID: "2026-07",
            transactions: transactions,
            transferAccountIDsByPayeeID: [:],
            offBudgetAccountIDs: []
        )

        #expect(alerts.map(\.kind) == ["toBudget", "overspending", "uncategorizedTransactions"])
    }

    @Test func openCachedBudgetUsesImportedDatabaseWithoutTokenOrNetwork() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistCachedBudget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fixtureURL = try makeSQLiteFixture()
        let fileID = "file-1"
        let budgetDirectory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: budgetDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: fileManager.databaseURL(fileID: fileID))
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: "group-1",
            budgetName: "Cached Budget",
            encryptionKeyID: nil,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(metadata).write(to: fileManager.metadataURL(fileID: fileID))
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            ),
            fileManager: fileManager
        )
        let budget = ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: "group-1",
            name: "Cached Budget",
            state: nil
        )

        let didOpen = try await store.openCachedBudget(budget)

        #expect(didOpen)
        #expect(store.isOpen(budgetID: "group-1"))
        let loaded = try await store.currentBudgetMonth(budgetID: "group-1", preferredMonth: "2026-07")
        #expect(loaded.month.month == "2026-07")
    }

    @Test func budgetMonthHonorsExplicitSelectionOutsideDiscoveredMonths() async throws {
        let store = try await makeOpenedWritableStore()

        let loaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-06")

        #expect(loaded.selectedMonth == "2026-06")
        #expect(loaded.month.month == "2026-06")
        #expect(loaded.availableMonths.contains("2026-07"))
    }

    @Test func openedStoreRejectsMismatchedBudgetReads() async throws {
        let store = try await makeOpenedWritableStore()

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await store.budgetMonth(budgetID: "group-2", selectedMonth: "2026-07")
        }
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refreshAccountsWithBalances(budgetID: "group-2")
        }
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refreshAccountTransactions(budgetID: "group-2", accountID: "checking")
        }
    }

    @Test func openedStoreRejectsMismatchedBudgetWrites() async throws {
        let store = try await makeOpenedWritableStore()
        var didAssign = false
        var didCreate = false
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 8),
            amountMinorUnits: -450,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await store.assignCategoryBudgetAndRefresh(
                categoryID: "groceries",
                budgeted: 10_000,
                budgetID: "group-2",
                month: "2026-07"
            ) {
                didAssign = true
            }
        }
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            _ = try await store.createTransactionAndRefresh(draft, budgetID: "group-2") {
                didCreate = true
            }
        }

        #expect(!didAssign)
        #expect(!didCreate)
    }

    @Test func createTransactionLocallyWithExistingPayeeRefreshesCaches() async throws {
        let store = try await makeOpenedWritableStore()
        var didCreate = false
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 8),
            amountMinorUnits: -450,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "morning",
            cleared: true,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {
            didCreate = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        #expect(didCreate)
        #expect(result.ok)
        #expect(result.changed.accounts == ["checking"])
        #expect(result.changed.months == ["2026-07"])
        #expect(created.amount == -450)
        #expect(created.payee == "coffee")
        #expect(created.payeeName == "Coffee Shop")
        #expect(created.category == "groceries")
        #expect(created.notes == "morning")
        #expect(created.cleared == .bool(true))
        #expect(loaded.balance == -12_795)
    }

    @Test func createTransactionLocallyCreatesTypedNewPayee() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 9),
            amountMinorUnits: -725,
            payeeID: nil,
            payeeName: "New Cafe",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-07")
        let newPayee = try #require(options.payees.first { $0.name == "New Cafe" })
        #expect(created.payee == newPayee.id)
        #expect(created.payeeName == "New Cafe")
        #expect(created.category == nil)
        #expect(created.cleared == .bool(false))
        #expect(loaded.payeeNames[newPayee.id ?? ""] == "New Cafe")
    }

    @Test func createTransactionLocallyReusesTypedPayeeNameCaseInsensitively() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 10),
            amountMinorUnits: -900,
            payeeID: nil,
            payeeName: "coffee shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let created = try #require(loaded.transactions.first { $0.id == result.changed.transactions.first })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-07")
        #expect(created.payee == "coffee")
        #expect(created.payeeName == "Coffee Shop")
        #expect(options.payees.filter { $0.name.caseInsensitiveCompare("coffee shop") == .orderedSame }.count == 1)
    }

    @Test func categorizeTransactionLocallyRefreshesCachesAndUncategorizedList() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let uncategorizedBefore = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let transactionID = try #require(createResult.changed.transactions.first)
        let transaction = try #require(uncategorizedBefore.transactions.first { $0.id == transactionID })
        var didUpdate = false

        let categorizeResult = try await store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "groceries",
            budgetID: "group-1"
        ) {
            didUpdate = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let categorized = try #require(loaded.transactions.first { $0.id == transactionID })
        let uncategorizedAfter = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didUpdate)
        #expect(categorizeResult.ok)
        #expect(categorizeResult.changed.accounts == ["checking"])
        #expect(categorizeResult.changed.months == ["2026-07"])
        #expect(categorizeResult.changed.transactions == [transactionID])
        #expect(categorized.category == "groceries")
        #expect(!uncategorizedAfter.transactions.contains { $0.id == transactionID })
        #expect(groceries.spent == -13_070)
    }

    @Test func createAccountLocallyWritesAccountTransferPayeeAndOutboxMessages() async throws {
        let store = try await makeOpenedWritableStore()

        try await store.createAccountAndRefresh(
            budgetID: "group-1",
            name: "Travel Checking",
            offbudget: false
        )

        let accounts = store.accountDisplays(budgetID: "group-1")
        let account = try #require(accounts.map(\.account).first { $0.name == "Travel Checking" })
        let accountDisplay = try #require(accounts.first { $0.account.id == account.id })
        let database = try #require(store.database)
        let transferPayee = try #require(
            try await database.fetchPayees().first { $0.transferAccount == account.id }
        )

        #expect(!account.offbudget)
        #expect(!account.closed)
        #expect(accountDisplay.balance == 0)
        #expect(transferPayee.name.isEmpty)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func createOffBudgetAccountLocallyMarksAccountAsOffBudget() async throws {
        let store = try await makeOpenedWritableStore()

        try await store.createAccountAndRefresh(
            budgetID: "group-1",
            name: "Brokerage",
            offbudget: true
        )

        let account = try #require(
            store.accountDisplays(budgetID: "group-1").map(\.account).first { $0.name == "Brokerage" }
        )

        #expect(account.offbudget)
        #expect(!account.closed)
    }

    @Test func assignCategoryBudgetLocallyRefreshesBudgetMonth() async throws {
        let store = try await makeOpenedWritableStore()
        var didAssign = false

        let loaded = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {
            didAssign = true
        }

        let groceries = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })
        let reloaded = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let reloadedGroceries = try #require(reloaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didAssign)
        #expect(groceries.budgeted == 62_500)
        #expect(groceries.spent == -12_345)
        #expect(groceries.balance == 50_155)
        #expect(loaded.month.totalBudgeted == 62_500)
        #expect(loaded.month.toBudget == -62_500)
        #expect(reloadedGroceries.budgeted == 62_500)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func categoryCarryoverPersistsForwardFromTheSelectedMonth() async throws {
        let store = try await makeOpenedWritableStore()
        var didSetCarryover = false

        let loaded = try await store.setCategoryCarryoverAndRefresh(
            categoryID: "utilities",
            carryover: true,
            budgetID: "group-1",
            startMonth: "2026-07"
        ) {
            didSetCarryover = true
        }

        let julyUtilities = try #require(
            loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )
        let august = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-08"
        )
        let augustUtilities = try #require(
            august.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )

        #expect(didSetCarryover)
        #expect(julyUtilities.carryover)
        #expect(augustUtilities.carryover)

        _ = try await store.setCategoryCarryoverAndRefresh(
            categoryID: "utilities",
            carryover: false,
            budgetID: "group-1",
            startMonth: "2026-08"
        ) {}

        let reloadedJuly = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let reloadedAugust = try await store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-08"
        )
        let reloadedJulyUtilities = try #require(
            reloadedJuly.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )
        let reloadedAugustUtilities = try #require(
            reloadedAugust.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" }
        )

        #expect(reloadedJulyUtilities.carryover)
        #expect(!reloadedAugustUtilities.carryover)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func localWriteOutboxSurvivesReopeningCachedBudget() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        let reopened = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            ),
            fileManager: bundle.fileManager
        )
        _ = try await reopened.openCachedBudget(bundle.budget)

        #expect(pendingCount > 0)
        #expect(try await reopened.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingCount)
    }

    @Test func refreshDrainsPendingLocalOutboxMessages() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")

        #expect(pendingCount > 0)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.pendingLocalMessageCount == 0)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
        #expect(await transport.messageCounts() == [pendingCount, 0, 0])
    }

    @Test func successfulHTTPWithoutServerConfirmationKeepsPendingOutboxRows() async throws {
        let transport = RecordingSyncTransport(dropsUploadedMessages: true)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        await #expect(throws: LocalFirstError.syncUploadNotConfirmed(pendingCount)) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }

        #expect(pendingCount > 0)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == pendingCount)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError?.contains("did not confirm") == true)
        #expect(await transport.messageCounts() == [pendingCount, 0])
    }

    @Test func failedRefreshKeepsPendingOutboxRowsForRetry() async throws {
        let transport = RecordingSyncTransport(shouldFail: true)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        await #expect(throws: LocalFirstTestSyncError.failed) {
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }
        let fileID = try #require(bundle.budget.localFirstFileID)
        let database = try BudgetDatabase(databaseURL: bundle.fileManager.databaseURL(fileID: fileID))
        let pending = try await database.pendingLocalSyncMessages()

        #expect(pendingCount > 0)
        #expect(pending.count == pendingCount)
        #expect(pending.allSatisfy { $0.attemptCount == 1 })
        #expect(pending.allSatisfy { ($0.lastError ?? "").isEmpty == false })
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.pendingLocalMessageCount == pendingCount)
    }

    @Test func scheduledFlushRetriesTransientFailureAndConfirmsUpload() async throws {
        let transport = RecordingSyncTransport(failureCount: 1)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport },
            pendingLocalMessageFlushRetryDelays: [.zero, .milliseconds(50)]
        )
        try bundle.keychain.saveActualSyncToken("token")
        bundle.store.openedServerURLString = "https://sync.example"

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        try await Task.sleep(for: .milliseconds(150))

        #expect(pendingCount > 0)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastUploadedMessageCount == pendingCount)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
        #expect(await transport.messageCounts() == [pendingCount, 0])
    }

    @Test func concurrentRefreshesCoalescePendingOutboxFlushes() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 80_000_000)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        _ = try await bundle.store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "utilities",
                amount: 2_500
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        _ = try await bundle.store.createTransactionAndRefresh(
            TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 16),
                amountMinorUnits: -450,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            budgetID: "group-1"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")

        let firstRefresh = Task { @MainActor in
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }
        let secondRefresh = Task { @MainActor in
            try await bundle.store.refresh(budgetID: "group-1", serverURLString: "https://sync.example")
        }
        try await firstRefresh.value
        try await secondRefresh.value

        let messageCounts = await transport.messageCounts()
        let nonEmptyFlushes = messageCounts.filter { $0 > 0 }
        #expect(pendingCount > 0)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(nonEmptyFlushes == [pendingCount])
    }

    @Test func appStateConcurrentManualRefreshesJoinOneSync() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 80_000_000)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        let firstRefresh = Task { @MainActor in
            await appState.refreshLocalFirstData(budgetID: "group-1", force: true)
        }
        let secondRefresh = Task { @MainActor in
            await appState.refreshLocalFirstData(budgetID: "group-1", force: true)
        }

        #expect(await firstRefresh.value)
        #expect(await secondRefresh.value)
        #expect(await transport.messageCounts() == [0])
        #expect(appState.localDataRevision == 1)
        #expect(appState.connectionStatus == .online)
    }

    @Test func appStateAutomaticallySyncsOncePerForegroundSession() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        await appState.beginForegroundSession()
        await appState.beginForegroundSession()

        #expect(appState.setupPhase == .ready)
        #expect(await transport.messageCounts() == [0])

        appState.endForegroundSession()
        await appState.beginForegroundSession()

        #expect(await transport.messageCounts() == [0, 0])
    }

    @Test func appStateKeepsRestoredSQLiteDataVisibleWhenForegroundSyncFails() async throws {
        let transport = RecordingSyncTransport(shouldFail: true)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)

        #expect(appState.setupPhase == .restoringBudget)

        await appState.beginForegroundSession()

        let loaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .offline)
        #expect(appState.localDataRevision == 1)
        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" })
    }

    @Test func appStateRestoresSelectedSQLiteBudgetWithoutSyncCredentials() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)

        #expect(appState.setupPhase == .restoringBudget)
        #expect(appState.connectionStatus == .offline)

        await appState.beginForegroundSession()

        let loaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .offline)
        #expect(loaded.month.categoryGroups.flatMap(\.categories).contains { $0.id == "groceries" })
    }

    @Test func moveMoneyLocallyMovesBudgetBetweenCategories() async throws {
        let store = try await makeOpenedWritableStore()
        var didMove = false

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "utilities",
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {
            didMove = true
        }

        let categories = Dictionary(uniqueKeysWithValues: loaded.month.categoryGroups.flatMap(\.categories).map { ($0.id, $0) })
        let groceries = try #require(categories["groceries"])
        let utilities = try #require(categories["utilities"])

        #expect(didMove)
        #expect(groceries.budgeted == 40_000)
        #expect(groceries.balance == 27_655)
        #expect(utilities.budgeted == 10_000)
        #expect(utilities.balance == 10_000)
        #expect(loaded.month.totalBudgeted == 50_000)
        #expect(loaded.month.toBudget == -50_000)
    }

    @Test func moveMoneyLocallyMovesBudgetBackToToBudget() async throws {
        let store = try await makeOpenedWritableStore()

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: nil,
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let groceries = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(groceries.budgeted == 40_000)
        #expect(groceries.balance == 27_655)
        #expect(loaded.month.totalBudgeted == 40_000)
        #expect(loaded.month.toBudget == -40_000)
    }

    @Test func moveMoneyLocallyCoversOverspentCategory() async throws {
        let store = try await makeOpenedWritableStore()
        let overspend = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -10_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "utilities",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        _ = try await store.createTransactionAndRefresh(overspend, budgetID: "group-1") {}
        let before = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let beforeUtilities = try #require(before.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: "utilities",
                amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let utilities = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })

        #expect(beforeUtilities.balance == -10_000)
        #expect(before.alerts.contains { $0.kind == "overspending" })
        #expect(utilities.budgeted == 10_000)
        #expect(utilities.balance == 0)
        #expect(!loaded.alerts.contains { $0.kind == "overspending" })
    }

    @Test func applyCategoryTemplateSetsFixedSimpleAmount() async throws {
        let store = try await makeOpenedWritableStore()
        // utilities has a `#template 300` goal_def and a current budget of 0.
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("utilities"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let utilities = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })
        let database = try #require(store.database)
        let pendingMessages = try await database.pendingLocalSyncMessages().map(\.message)
        let utilityBudgetMessages = pendingMessages.filter {
            $0.dataset == "zero_budgets" && $0.row == "202607-utilities"
        }
        #expect(utilities.budgeted == 30_000)
        #expect(utilityBudgetMessages.map(\.column) == ["month", "category", "amount"])
        #expect(utilityBudgetMessages.map(\.serializedValue) == ["N:202607", "S:utilities", "N:30000"])
    }

    @Test func applyCategoryTemplateSetsPeriodicAmount() async throws {
        let store = try await makeOpenedWritableStore()
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("subscriptions"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let subscriptions = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "subscriptions" })
        #expect(subscriptions.budgeted == 4_500)
    }

    @Test func applyCategoryTemplateCopiesPreviousMonthBudget() async throws {
        let store = try await makeOpenedWritableStore()
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "copycat",
            budgeted: 2_500,
            budgetID: "group-1",
            month: "2026-06"
        ) {}
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("copycat"),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let copycat = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "copycat" })
        #expect(copycat.budgeted == 2_500)
    }

    @Test func applyMonthTemplateFillEmptyOnlyFillsUnbudgetedAndSkipsUnsupported() async throws {
        let store = try await makeOpenedWritableStore()
        // Budget dining so its unsupported average template is skipped by fill-empty (already
        // budgeted). groceries is already budgeted (50000, template 700); utilities is unbudgeted
        // (template 300) and should be the only category filled.
        _ = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "dining",
            budgeted: 5_000,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .fillEmpty,
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let categories = loaded.month.categoryGroups.flatMap(\.categories)
        let groceries = try #require(categories.first { $0.id == "groceries" })
        let utilities = try #require(categories.first { $0.id == "utilities" })
        let dining = try #require(categories.first { $0.id == "dining" })

        #expect(utilities.budgeted == 30_000)   // was 0 -> filled
        #expect(groceries.budgeted == 50_000)   // already budgeted -> untouched (not 70000)
        #expect(dining.budgeted == 5_000)        // unsupported but already budgeted -> skipped
    }

    @Test func applyMonthTemplateOverwriteRefusesUnsupportedTemplate() async throws {
        let store = try await makeOpenedWritableStore()
        // Whole-month overwrite would write dining, whose average template is not supported yet.
        await #expect(throws: LocalFirstError.self) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                command: .overwrite,
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
        // Nothing was written: utilities stays at its original 0 budget.
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let utilities = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "utilities" })
        #expect(utilities.budgeted == 0)
    }

    @Test func applyCategoryTemplateRefusesUnsupportedTargetedCategory() async throws {
        let store = try await makeOpenedWritableStore()
        await #expect(throws: LocalFirstError.self) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                command: .category("dining"),
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
    }

    @Test func updateSimpleTransactionLocallyRefreshesMovedAccountMonthAndPayeeOptions() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "old note",
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(createResult.changed.transactions.first)
        let updateDraft = TransactionDraft(
            accountID: "credit",
            date: try makeDate(year: 2026, month: 8, day: 2),
            amountMinorUnits: 425,
            payeeID: nil,
            payeeName: "Edited Payee",
            categoryID: nil,
            notes: "updated note",
            cleared: true,
            isTransfer: false
        )
        var didUpdate = false

        let updateResult = try await store.updateTransactionAndRefresh(
            transactionID,
            with: updateDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {
            didUpdate = true
        }

        let oldAccount = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let newAccount = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let updated = try #require(newAccount.transactions.first { $0.id == transactionID })
        let options = try await store.editorOptions(budgetID: "group-1", month: "2026-08")

        #expect(didUpdate)
        #expect(updateResult.ok)
        #expect(Set(updateResult.changed.accounts) == Set(["checking", "credit"]))
        #expect(Set(updateResult.changed.months) == Set(["2026-07", "2026-08"]))
        #expect(updateResult.changed.transactions == [transactionID])
        #expect(!oldAccount.transactions.contains { $0.id == transactionID })
        #expect(updated.account == "credit")
        #expect(updated.date == "2026-08-02")
        #expect(updated.amount == 425)
        #expect(updated.payeeName == "Edited Payee")
        #expect(updated.category == nil)
        #expect(updated.notes == "updated note")
        #expect(updated.cleared?.boolValue == true)
        #expect(options.payees.contains { $0.name == "Edited Payee" })
    }

    @Test func deleteSimpleTransactionLocallyTombstonesAndRefreshesCaches() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 11),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let createResult = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(createResult.changed.transactions.first)
        let created = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        // Groceries baseline is the single seeded -12345 transaction; the created -725 adds to it.
        let monthBeforeDelete = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesBeforeDelete = try #require(
            monthBeforeDelete.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        #expect(groceriesBeforeDelete.spent == -13_070)
        var didDelete = false

        let deleteResult = try await store.deleteTransactionAndRefresh(
            created,
            budgetID: "group-1"
        ) {
            didDelete = true
        }

        let loaded = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(didDelete)
        #expect(deleteResult.ok)
        #expect(deleteResult.changed.accounts == ["checking"])
        #expect(deleteResult.changed.months == ["2026-07"])
        #expect(deleteResult.changed.transactions == [transactionID])
        #expect(!loaded.transactions.contains { $0.id == transactionID })
        #expect(groceries.spent == -12_345)
    }

    @Test func createTransferLocallyWritesPairedRowsAcrossAccounts() async throws {
        let store = try await makeOpenedWritableStore()
        // Transfer $10.00 out of checking into credit: payee is the credit account's transfer payee.
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: "move to card",
            cleared: false,
            isTransfer: true
        )
        var didCreate = false

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {
            didCreate = true
        }

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let source = try #require(checking.transactions.first { $0.id == result.changed.transactions.first })
        let paired = try #require(credit.transactions.first { $0.amount == 1000 })

        #expect(didCreate)
        #expect(result.ok)
        #expect(Set(result.changed.accounts) == Set(["checking", "credit"]))
        #expect(source.amount == -1000)
        #expect(source.category == nil)
        // The transfer feed resolves the empty-named transfer payee to the linked account name.
        #expect(source.payeeName == "Credit Card")
        #expect(paired.amount == 1000)
        #expect(paired.category == nil)
        #expect(paired.payeeName == "Checking")
        #expect(paired.account == "credit")
    }

    @Test func createCrossBudgetTransferKeepsCategoryOnOnBudgetSide() async throws {
        let store = try await makeOpenedWritableStore()
        // checking (on-budget) -> tracking (off-budget): the on-budget source keeps its category.
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-tracking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        let tracking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking"))
        let paired = try #require(tracking.transactions.first { $0.amount == 1000 })

        #expect(source.category == "groceries")
        #expect(paired.category == nil)
    }

    @Test func createReverseCrossBudgetTransferPutsCategoryOnOnBudgetPair() async throws {
        let store = try await makeOpenedWritableStore()
        // tracking (off-budget) -> checking (on-budget): the generated on-budget row receives
        // the category selected in the editor.
        let draft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-checking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let paired = try #require(
            checking.transactions.first {
                $0.amount == 1000 && $0.payeeName == "Tracking"
            }
        )

        #expect(source.category == nil)
        #expect(paired.category == "groceries")
    }

    @Test func createSameBudgetTransferClearsCategoryEvenIfProvided() async throws {
        let store = try await makeOpenedWritableStore()
        // checking -> credit, both on-budget: category must be cleared even if a draft carries one.
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == result.changed.transactions.first }
        )
        #expect(source.category == nil)
    }

    @Test func editSimpleToCrossBudgetTransferKeepsCategory() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        // Convert to a cross-budget transfer to the off-budget account, keeping the category.
        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-tracking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(source.category == "groceries")
    }

    @Test func editOffBudgetSimpleToCrossBudgetTransferCategorizesOnBudgetPair() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let transferDraft = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-checking",
            payeeName: "",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "tracking",
            originalMonth: "2026-07"
        ) {}

        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "tracking")?
                .transactions.first { $0.id == transactionID }
        )
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let paired = try #require(
            checking.transactions.first {
                $0.amount == 1000 && $0.payeeName == "Tracking"
            }
        )

        #expect(source.category == nil)
        #expect(paired.category == "groceries")
    }

    @Test func createSplitLocallyWritesParentAndChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let parent = try #require(checking.transactions.first { $0.id == result.changed.transactions.first })
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(result.ok)
        #expect(parent.isParent)
        #expect(parent.category == nil)
        #expect(parent.amount == -3000)
        #expect(parent.subtransactions.count == 2)
        #expect(parent.subtransactions.allSatisfy { $0.category == "groceries" })
        #expect(parent.subtransactions.reduce(0) { $0 + ($1.amount ?? 0) } == -3000)
        // Baseline groceries spend is -12345; the split children add another -3000.
        #expect(groceries.spent == -15_345)
    }

    @Test func createSplitLocallyRejectsAmountMismatch() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -500)
            ]
        )

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        }
    }

    @Test func editSplitLocallyUpdatesAddsAndRemovesChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let createDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        let created = try await store.createTransactionAndRefresh(createDraft, budgetID: "group-1") {}
        let parentID = try #require(created.changed.transactions.first)
        let parent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )
        let keptChildID = try #require(parent.subtransactions.first?.id)
        let removedChildID = try #require(parent.subtransactions.last?.id)

        // Keep the first child (re-amounted to -1500), drop the second, add a new -1500 child.
        let updateDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: keptChildID, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1500),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1500)
            ]
        )

        _ = try await store.updateTransactionAndRefresh(
            parentID,
            with: updateDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let updatedParent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(updatedParent.subtransactions.count == 2)
        #expect(!updatedParent.subtransactions.contains { $0.id == removedChildID })
        #expect(updatedParent.subtransactions.contains { $0.id == keptChildID })
        #expect(updatedParent.subtransactions.reduce(0) { $0 + ($1.amount ?? 0) } == -3000)
        // Baseline -12345 plus the split total -3000 (unchanged across the edit).
        #expect(groceries.spent == -15_345)
    }

    @Test func editSimpleToTransferAndBackTogglesPairedRow() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: transferDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let creditAfterTransfer = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let paired = try #require(creditAfterTransfer.transactions.first { $0.amount == 1000 })
        let sourceAfterTransfer = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(sourceAfterTransfer.category == nil)
        #expect(paired.payeeName == "Checking")

        // Now revert to a simple categorized transaction: the paired row must disappear.
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: simpleDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let creditAfterRevert = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let sourceAfterRevert = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(!creditAfterRevert.transactions.contains { $0.id == paired.id })
        #expect(sourceAfterRevert.category == "groceries")
    }

    @Test func editTransferLocallyRepointsPairedAmountAndDestination() async throws {
        let store = try await makeOpenedWritableStore()
        let createDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let created = try await store.createTransactionAndRefresh(createDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        // Repoint to savings and change the amount to -2500.
        let editDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -2500,
            payeeID: "xfer-savings",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: editDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let savings = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "savings"))
        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        let paired = try #require(savings.transactions.first { $0.amount == 2500 })

        #expect(source.amount == -2500)
        #expect(credit.transactions.isEmpty)
        #expect(paired.account == "savings")
        #expect(paired.payeeName == "Checking")
    }

    @Test func editSimpleToSplitAndBackTogglesChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let simpleDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let created = try await store.createTransactionAndRefresh(simpleDraft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)

        let splitDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: splitDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let asSplit = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(asSplit.isParent)
        #expect(asSplit.category == nil)
        #expect(asSplit.subtransactions.count == 2)

        // Revert to simple.
        _ = try await store.updateTransactionAndRefresh(
            transactionID,
            with: simpleDraft,
            budgetID: "group-1",
            originalAccountID: "checking",
            originalMonth: "2026-07"
        ) {}

        let asSimple = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(!asSimple.isParent)
        #expect(asSimple.subtransactions.isEmpty)
        #expect(asSimple.category == "groceries")
    }

    @Test func deleteSplitParentLocallyTombstonesParentAndChildren() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 13),
            amountMinorUnits: -3000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false,
            splits: [
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -2000),
                TransactionSplitDraft(id: nil, categoryID: "groceries", categoryName: "Groceries", amountMinorUnits: -1000)
            ]
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let parentID = try #require(created.changed.transactions.first)
        let parent = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == parentID }
        )

        let result = try await store.deleteTransactionAndRefresh(parent, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let month = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceries = try #require(month.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" })

        #expect(result.ok)
        #expect(!checking.transactions.contains { $0.id == parentID })
        // The two child ids are reported as affected (tombstoned) alongside the parent.
        #expect(result.changed.transactions.count == 3)
        // Split children removed, so groceries returns to the seeded baseline.
        #expect(groceries.spent == -12_345)
    }

    @Test func deleteTransferLocallyTombstonesBothSides() async throws {
        let store = try await makeOpenedWritableStore()
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -1000,
            payeeID: "xfer-credit",
            payeeName: "",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let created = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        let transactionID = try #require(created.changed.transactions.first)
        let source = try #require(
            store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking")?
                .transactions.first { $0.id == transactionID }
        )
        #expect(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit")?.transactions.isEmpty == false)

        let result = try await store.deleteTransactionAndRefresh(source, budgetID: "group-1") {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))

        #expect(result.ok)
        #expect(Set(result.changed.accounts) == Set(["checking", "credit"]))
        #expect(!checking.transactions.contains { $0.id == transactionID })
        #expect(credit.transactions.isEmpty)
    }

    private func makeBudgetMonth(
        toBudget: Int,
        groups: [BudgetMonthCategoryGroup] = []
    ) -> BudgetMonth {
        BudgetMonth(
            month: "2026-07",
            incomeAvailable: 0,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: 0,
            toBudget: toBudget,
            fromLastMonth: 0,
            totalIncome: 0,
            totalSpent: 0,
            totalBalance: 0,
            categoryGroups: groups
        )
    }

    private func makeGroup(
        id: String,
        isIncome: Bool,
        categories: [BudgetMonthCategory]
    ) -> BudgetMonthCategoryGroup {
        BudgetMonthCategoryGroup(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: false,
            budgeted: 0,
            spent: 0,
            balance: 0,
            categories: categories
        )
    }

    private func makeCategory(
        id: String,
        balance: Int,
        hidden: Bool = false
    ) -> BudgetMonthCategory {
        BudgetMonthCategory(
            id: id,
            name: id,
            isIncome: false,
            hidden: hidden,
            groupID: "group",
            budgeted: 0,
            spent: 0,
            balance: balance,
            carryover: false
        )
    }

    private func testResourceLimits(
        maximumCompressedBudgetBytes: UInt64 = 1_024,
        maximumExpandedBudgetBytes: UInt64 = 1_024,
        maximumArchiveEntryBytes: UInt64 = 1_024,
        maximumArchiveEntryCount: Int = 10,
        maximumArchivePathDepth: Int = 4,
        maximumSyncResponseBytes: Int = 1_024
    ) -> LocalFirstResourceLimits {
        LocalFirstResourceLimits(
            maximumCompressedBudgetBytes: maximumCompressedBudgetBytes,
            maximumExpandedBudgetBytes: maximumExpandedBudgetBytes,
            maximumArchiveEntryBytes: maximumArchiveEntryBytes,
            maximumArchiveEntryCount: maximumArchiveEntryCount,
            maximumArchivePathDepth: maximumArchivePathDepth,
            minimumFreeDiskReserveBytes: 0,
            maximumSyncResponseBytes: maximumSyncResponseBytes
        )
    }

    private func makeArchive(at url: URL, entries: [(String, Data)]) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
    }

    private func markBudgetArtifactAsUnhardened(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try mutableURL.setResourceValues(values)
        #if os(iOS) && !targetEnvironment(simulator)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func expectBudgetArtifactIsHardened(_ url: URL) throws {
        #if os(iOS) && !targetEnvironment(simulator)
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(
            attributes[.protectionKey] as? FileProtectionType
                == .completeUntilFirstUserAuthentication
        )
        #else
        // Simulator file metadata is not evidence of effective iOS protection or backup policy.
        #expect(FileManager.default.fileExists(atPath: url.path))
        #endif
    }

    private func makeArchiveData(databaseURL: URL) throws -> Data {
        let archiveURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistReimport-\(UUID().uuidString).zip")
        try makeArchive(
            at: archiveURL,
            entries: [("db.sqlite", try Data(contentsOf: databaseURL))]
        )
        return try Data(contentsOf: archiveURL)
    }

    private func testRemoteFile() -> ActualSyncRemoteFile {
        ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Budget"
        )
    }

    private func testBudgetMetadata() -> LocalFirstBudgetMetadata {
        LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Budget",
            encryptionKeyID: nil,
            nodeID: "node"
        )
    }

    private func makeTransaction(
        id: String,
        account: String = "checking",
        category: String?,
        payee: String? = nil,
        date: String = "2026-07-03",
        isParent: Bool = false,
        subtransactions: [ActualTransaction] = []
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: account,
            date: date,
            amount: -1000,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: category,
            notes: nil,
            cleared: nil,
            subtransactions: subtransactions,
            isParent: isParent
        )
    }

    private func makeStore() -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )
    }

    private func makeOpenedWritableStore() async throws -> LocalFirstActualStore {
        try await makeOpenedWritableStoreBundle().store
    }

    private func makeAppState(for bundle: OpenedWritableStoreBundle) throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.save(
            AppSettings(
                localFirstServerURLString: "https://sync.example",
                selectedBudgetID: "group-1",
                selectedBudgetName: "Writable Budget",
                selectedLocalFirstFileID: "file-1",
                selectedLocalFirstGroupID: "group-1"
            )
        )
        return AppState(
            settingsStore: settingsStore,
            keychain: bundle.keychain,
            localFirstStore: bundle.store
        )
    }

    private func makeOpenedWritableStoreBundle(
        syncTransportFactory: @escaping @Sendable (URL) -> any ActualSyncTransport = { ActualServerSyncClient(baseURL: $0) },
        connectionTransportFactory: @escaping @Sendable (URL) -> any ActualServerConnectionTransport = {
            ActualServerSyncClient(baseURL: $0)
        },
        pendingLocalMessageFlushRetryDelays: [Duration] = [.zero, .seconds(2), .seconds(8), .seconds(30)],
        additionalFixtureSQL: String = "",
        reimportFailureCheckpoint: BudgetReimportCheckpoint? = nil
    ) async throws -> OpenedWritableStoreBundle {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            ALTER TABLE transactions ADD COLUMN notes TEXT;
            ALTER TABLE transactions ADD COLUMN cleared INTEGER;
            ALTER TABLE transactions ADD COLUMN transferred_id TEXT;
            ALTER TABLE transactions ADD COLUMN isChild INTEGER;
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            INSERT INTO payees VALUES ('coffee', 'Coffee Shop', NULL, 0);
            INSERT INTO payee_mapping VALUES ('coffee', 'coffee');
            INSERT INTO categories VALUES ('utilities', 'Utilities', 'group', 0, 0, 0, 2);
            INSERT INTO category_mapping VALUES ('utilities', 'utilities');
            INSERT INTO zero_budgets VALUES (202607, 'utilities', 0, 0);
            INSERT INTO accounts VALUES ('credit', 'Credit Card', 0, 0, 0, 2);
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 3);
            INSERT INTO accounts VALUES ('tracking', 'Tracking', 1, 0, 0, 4);
            INSERT INTO payees VALUES ('xfer-checking', '', 'checking', 0);
            INSERT INTO payees VALUES ('xfer-credit', '', 'credit', 0);
            INSERT INTO payees VALUES ('xfer-savings', '', 'savings', 0);
            INSERT INTO payees VALUES ('xfer-tracking', '', 'tracking', 0);
            INSERT INTO payee_mapping VALUES ('xfer-checking', 'xfer-checking');
            INSERT INTO payee_mapping VALUES ('xfer-credit', 'xfer-credit');
            INSERT INTO payee_mapping VALUES ('xfer-savings', 'xfer-savings');
            INSERT INTO payee_mapping VALUES ('xfer-tracking', 'xfer-tracking');
            ALTER TABLE categories ADD COLUMN goal_def TEXT;
            UPDATE categories SET goal_def = '[{"type":"simple","monthly":700,"limit":null,"priority":null,"directive":"template"}]' WHERE id = 'groceries';
            UPDATE categories SET goal_def = '[{"type":"simple","monthly":300,"limit":null,"priority":null,"directive":"template"}]' WHERE id = 'utilities';
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('dining', 'Dining', 'group', 0, 0, 0, 3, '[{"type":"average","numMonths":3,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('dining', 'dining');
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('subscriptions', 'Subscriptions', 'group', 0, 0, 0, 4, '[{"type":"periodic","amount":45,"period":{"amount":1,"period":"month"},"starting":"2026-07-01","limit":null,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('subscriptions', 'subscriptions');
            INSERT INTO zero_budgets VALUES (202607, 'subscriptions', 0, 0);
            INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order, goal_def)
                VALUES ('copycat', 'Copycat', 'group', 0, 0, 0, 5, '[{"type":"copy","lookBack":1,"limit":null,"priority":null,"directive":"template"}]');
            INSERT INTO category_mapping VALUES ('copycat', 'copycat');
            INSERT INTO zero_budgets VALUES (202607, 'copycat', 0, 0);
            \(additionalFixtureSQL)
            """)
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistWritableStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(
            applicationSupportURL: rootURL,
            reimportFailureInjector: { checkpoint in
                if checkpoint == reimportFailureCheckpoint {
                    throw LocalFirstTestSyncError.failed
                }
            }
        )
        let fileID = "file-1"
        let budgetDirectory = try fileManager.budgetDirectory(fileID: fileID)
        try FileManager.default.createDirectory(at: budgetDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: fileManager.databaseURL(fileID: fileID))
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: fileID,
            cloudFileID: fileID,
            groupID: "group-1",
            budgetName: "Writable Budget",
            encryptionKeyID: nil,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(metadata).write(to: fileManager.metadataURL(fileID: fileID))
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: syncTransportFactory,
            connectionTransportFactory: connectionTransportFactory,
            pendingLocalMessageFlushRetryDelays: pendingLocalMessageFlushRetryDelays
        )
        let budget = ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: "group-1",
            name: "Writable Budget",
            state: nil
        )
        _ = try await store.openCachedBudget(budget)
        return OpenedWritableStoreBundle(store: store, fileManager: fileManager, keychain: keychain, budget: budget)
    }

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(components.date)
    }

    private func remoteMessage(
        index: Int,
        row: String,
        column: String,
        value: LocalFirstSyncValue
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: String(
                format: "2026-07-25T12:00:00.000Z-%04x-remote",
                index
            ),
            dataset: "transactions",
            row: row,
            column: column,
            serializedValue: value.serialized
        )
    }

    private func makeSQLiteFixture(extraSQL: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ActualistTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "db.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    offbudget INTEGER,
                    closed INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    cat_group TEXT,
                    is_income INTEGER,
                    hidden INTEGER,
                    tombstone INTEGER,
                    sort_order INTEGER
                );
                CREATE TABLE zero_budgets (
                    month INTEGER,
                    category TEXT,
                    amount INTEGER,
                    carryover INTEGER
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    date INTEGER,
                    amount INTEGER,
                    category TEXT,
                    tombstone INTEGER,
                    parent_id TEXT,
                    is_parent INTEGER
                );
                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );
                CREATE TABLE messages_crdt (
                    timestamp TEXT,
                    dataset TEXT,
                    row TEXT,
                    column TEXT,
                    value TEXT
                );
                INSERT INTO accounts VALUES ('checking', 'Checking', 0, 0, 0, 1);
                INSERT INTO category_groups VALUES ('group', 'Everyday', 0, 0, 0, 1);
                INSERT INTO categories VALUES ('groceries', 'Groceries', 'group', 0, 0, 0, 1);
                INSERT INTO category_mapping VALUES ('groceries', 'groceries');
                INSERT INTO zero_budgets VALUES (202607, 'groceries', 50000, 1);
                INSERT INTO transactions VALUES ('txn', 'checking', 20260703, -12345, 'groceries', 0, NULL, 0);
                """)
            if !extraSQL.isEmpty {
                try db.execute(sql: extraSQL)
            }
        }
        return url
    }
}
