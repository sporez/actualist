import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
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

    @Test func encryptionPasswordNoticeExplainsRecoveryResponsibility() {
        let notice = LocalFirstRecoveryGuidance.encryptionPasswordNotice

        #expect(notice.contains("cannot be recovered by Actualist"))
        #expect(notice.contains("Store it securely"))
        #expect(notice.contains("if this iPhone is lost or replaced"))
        #expect(notice.contains("not the password"))
        #expect(notice.contains("Neither is included in device backups"))
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

    @Test func serverConnectionSecurityHandlesEveryTypedURLPrefixAndEmptyHost() {
        let addresses = [
            "http://192.168.1.16:5007",
            "HTTP://localhost:5006",
            "http://actual.tailnet-name.ts.net:5006",
            "http://[fe80::1%25en0]:5006",
            "https://actual.example.com"
        ]
        let malformedEmptyHostInputs = [
            "http://",
            " http:// ",
            "http:///actual",
            "http://:5006",
            "http://?query",
            "http://#fragment",
            "http://[]",
            "http://%25",
            "http://%25%25"
        ]

        func verifySecurityClassificationDoesNotCrash(_ input: String) {
            let warning = ActualServerConnectionSecurity.warningMessage(for: input)
            let blocked = ActualServerConnectionSecurity.blockedMessage(for: input)

            #expect(
                warning == nil || blocked == nil,
                "An address must not be both warned and blocked: \(input)"
            )
        }

        for address in addresses {
            var typedPrefix = ""
            verifySecurityClassificationDoesNotCrash(typedPrefix)
            for character in address {
                typedPrefix.append(character)
                verifySecurityClassificationDoesNotCrash(typedPrefix)
            }
        }

        for input in malformedEmptyHostInputs {
            verifySecurityClassificationDoesNotCrash(input)
        }
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

}
