import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
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
        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        #expect(try await bundle.store.recentBudgetActions(budgetID: "group-1").isEmpty == false)

        try await bundle.store.reimportBudget(
            bundle.budget,
            serverURLString: "https://sync.example"
        )

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(try await bundle.store.recentBudgetActions(budgetID: "group-1").isEmpty)
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
}
