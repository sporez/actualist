import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreTests {
    @Test func settingsDecodeDefaultsToRestBackend() throws {
        let data = Data("""
        {
          "serverURLString": "http://localhost:5007/v1",
          "selectedBudgetID": "budget"
        }
        """.utf8)

        let settings = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(settings.backendMode == .restAPI)
        #expect(settings.localFirstServerURLString == "")
        #expect(settings.selectedLocalFirstFileID == nil)
    }

    @Test func loginResponseDecodesTopLevelAndNestedToken() throws {
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

    @Test func loginMethodsDecodeActualServerObjectShape() throws {
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

    @Test func userFilesDecodeDeletedFilteringInputs() throws {
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

    @Test func userFilesDecodeActualServerDataArrayShape() throws {
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
    }

    @Test func userFileInfoDecodesActualServerDataObjectShape() throws {
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
    }

    @Test func userFileInfoDetectsEncryptedDownloadMetadata() throws {
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
    }

    @Test func budgetDatabaseMapsAccountsBalancesAndBudgetMonth() throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let accounts = try database.fetchAccountDisplays()
        let months = try database.fetchAvailableMonths()
        let month = try database.fetchBudgetMonth(month: "2026-07")

        #expect(accounts.map(\.account.id) == ["checking"])
        #expect(accounts.first?.balance == -12_345)
        #expect(months == ["2026-07"])
        #expect(month.totalBudgeted == 50_000)
        #expect(month.totalSpent == -12_345)
        #expect(month.totalBalance == 37_655)
        #expect(month.categoryGroups.first?.categories.first?.carryover == true)
    }

    @Test func budgetDatabaseUsesActualiSpendingSemanticsForMappedSplits() throws {
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
        let month = try database.fetchBudgetMonth(month: "2026-08")
        let groceries = month.categoryGroups.first?.categories.first

        #expect(groceries?.budgeted == 50_000)
        #expect(groceries?.spent == -40_000)
        #expect(groceries?.balance == 10_000)
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

    @Test func refreshLocalFirstDataIsNoOpInRestMode() async {
        let state = makeAppState()
        state.settings.backendMode = .restAPI
        state.setupPhase = .ready
        state.connectionStatus = .online

        await state.refreshLocalFirstData(budgetID: "any")

        // REST mode: guard returns immediately, nothing mutated.
        #expect(state.connectionStatus == .online)
        #expect(state.localFirstSyncStatus == nil)
    }

    @Test func syncStatusDefaultsAndEquality() {
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

    @Test func accountFeedExcludesTombstonedAndAttachesSplits() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO transactions VALUES ('dead', 'checking', 20260702, -999, 'groceries', 1, NULL, 0);
            INSERT INTO transactions VALUES ('split', 'checking', 20260701, -5000, NULL, 0, NULL, 1);
            INSERT INTO transactions VALUES ('split-a', 'checking', 20260701, -2000, 'groceries', 0, 'split', 0);
            INSERT INTO transactions VALUES ('split-b', 'checking', 20260701, -3000, 'groceries', 0, 'split', 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let transactions = try database.fetchTransactions(accountID: "checking")
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

    @Test func spendingFeedSpansAccountsAndSearchFilters() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            INSERT INTO transactions VALUES ('txn2', 'savings', 20260704, -55500, 'groceries', 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let all = try database.fetchTransactions()
        #expect(Set(all.compactMap(\.id)) == ["txn", "txn2"])

        let search = try database.fetchTransactions(matching: "55500")
        #expect(search.compactMap(\.id) == ["txn2"])
    }

    @Test func accountFeedResolvesPayeeThroughPayeeMapping() throws {
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

        let amazon = try database.fetchTransactions(accountID: "checking").first { $0.id == "amz" }
        // The payee id lives in `description`; `amazon-src` remaps to the canonical `amazon` payee.
        #expect(amazon?.payee == "amazon")
        #expect(amazon?.payeeName == "Amazon")
    }

    @Test func feedResolvesTransferPayeeToAccountName() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            ALTER TABLE transactions ADD COLUMN description TEXT;
            INSERT INTO accounts VALUES ('savings', 'Savings', 0, 0, 0, 2);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER);
            INSERT INTO payees VALUES ('xfer', '', 'savings', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, description)
                VALUES ('t-xfer', 'checking', 20260706, -10000, NULL, 0, NULL, 0, 'xfer');
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let transfer = try database.fetchTransactions(accountID: "checking").first { $0.id == "t-xfer" }
        // Transfer payee has an empty name; the feed shows the linked account's name.
        #expect(transfer?.payeeName == "Savings")
    }

    @Test func refreshAccountTransactionsWithoutOpenBudgetThrows() async {
        let store = makeStore()
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refreshAccountTransactions(budgetID: "b", accountID: "a")
        }
    }

    @Test func deleteTransactionThrowsUnsupportedWriteInLocalFirst() async {
        let store = makeStore()
        let transaction = ActualTransaction(
            id: "x", account: "a", date: "2026-07-03", amount: -1,
            payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil, cleared: nil
        )
        await #expect(throws: LocalFirstError.unsupportedWrite) {
            _ = try await store.deleteTransactionAndRefresh(transaction, budgetID: "b") {}
        }
    }

    private func makeStore() -> LocalFirstActualStore {
        LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
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
