import Foundation
import GRDB
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreTests {
    @Test func settingsDecodeIgnoresRetiredRestKeysAndKeepsLocalFirst() throws {
        // Old persisted settings may still carry retired REST keys; they must be ignored while
        // local-first fields decode normally.
        let data = Data("""
        {
          "backendMode": "restAPI",
          "serverURLString": "http://localhost:5007/v1",
          "localFirstServerURLString": "https://actual.example.com",
          "selectedBudgetID": "budget"
        }
        """.utf8)

        let settings = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(settings.localFirstServerURLString == "https://actual.example.com")
        #expect(settings.selectedBudgetID == "budget")
        #expect(settings.selectedLocalFirstFileID == nil)
        #expect(!settings.localFirstTransactionCreationEnabled)
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
        #expect(response.files.first?.syncEncryptionKeyID == nil)
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
        #expect(response.file?.syncEncryptionKeyID == nil)
    }

    @Test func userFileInfoTreatsNullEncryptMetaAsUnencrypted() throws {
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
        #expect(response.file?.syncEncryptionKeyID == "key-1")
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

    @Test func toBudgetIsCumulativeAcrossMonthsNotJustCurrentMonth() throws {
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

        let month = try database.fetchBudgetMonth(month: "2026-07")

        // On-budget balance through July = 200000 - 40000 - 12345 = 147655.
        // Groceries balance carries June's 10000 leftover into July: 50000 - 12345 + 10000 = 47655.
        // To Budget = 147655 - 47655 = 100000 (i.e., total income 200000 - total budgeted 100000).
        // The old current-month-only formula would have reported 0 - 50000 = -50000.
        #expect(month.toBudget == 100_000)
    }

    @Test func toBudgetIgnoresUncategorizedActivityUntilCategorized() throws {
        let fixtureURL = try makeSQLiteFixture(extraSQL: """
            INSERT INTO category_groups VALUES ('income-grp', 'Income', 1, 0, 0, 0);
            INSERT INTO categories VALUES ('salary', 'Salary', 'income-grp', 1, 0, 0, 1);
            INSERT INTO category_mapping VALUES ('salary', 'salary');
            INSERT INTO transactions VALUES ('income', 'checking', 20260701, 200000, 'salary', 0, NULL, 0);
            INSERT INTO transactions VALUES ('mystery', 'checking', 20260705, -1000, NULL, 0, NULL, 0);
            """)
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let month = try database.fetchBudgetMonth(month: "2026-07")

        // Uncategorized spending changes account balance, but Actual does not let it reduce
        // To Budget until it is assigned to a category.
        #expect(month.toBudget == 150_000)
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

    @Test func localFirstSyncValueSerializesActualWireValues() {
        #expect(LocalFirstSyncValue.null.serialized == "0:")
        #expect(LocalFirstSyncValue.int(42).serialized == "N:42")
        #expect(LocalFirstSyncValue.double(12.5).serialized == "N:12.5")
        #expect(LocalFirstSyncValue.string("Coffee").serialized == "S:Coffee")
        #expect(LocalFirstSyncValue.bool(true).serialized == "N:1")
        #expect(LocalFirstSyncValue.bool(false).serialized == "N:0")
    }

    @Test func hybridLogicalClockUsesNodeIDAndIncrementsWhenWallClockDoesNotAdvance() {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )

        let first = clock.next(now: Date(timeIntervalSince1970: 1.0))
        let second = clock.next(now: Date(timeIntervalSince1970: 1.0))
        let advanced = clock.next(now: Date(timeIntervalSince1970: 2.0))

        #expect(first == "1970-01-01T00:00:01.234Z-0001-node1")
        #expect(second == "1970-01-01T00:00:01.234Z-0002-node1")
        #expect(advanced == "1970-01-01T00:00:02.000Z-0000-node1")
    }

    @Test func hybridLogicalClockUsesActualClientIDShape() {
        let uuid = UUID(uuidString: "A219E7A7-1CC1-8912-ABCD-0123456789AB")!

        #expect(HybridLogicalClock.makeClientID(uuid: uuid) == "abcd0123456789ab")
        #expect(HybridLogicalClock.normalizedNodeID("node-1") == "node1")
    }

    @Test func localFirstSyncMessageEnvelopeRoundTripsThroughProtobuf() throws {
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: "S:groceries"
        )

        let envelope = try LocalFirstSyncMessageBuilder.envelope(for: message)
        let decoded = try ActualSync_Message(serializedData: envelope.content)

        #expect(envelope.timestamp == message.timestamp)
        #expect(envelope.isEncrypted == false)
        #expect(decoded.dataset == "transactions")
        #expect(decoded.row == "txn")
        #expect(decoded.column == "category")
        #expect(decoded.value == "S:groceries")
    }

    @Test func applyLocalSyncMessagesUpdatesSQLiteAndMessagesTable() throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("gas").serialized
        )

        let appliedCount = try database.applyLocalSyncMessages([message])

        let transaction = try #require(database.fetchTransactions(accountID: "checking").first { $0.id == "txn" })
        #expect(appliedCount == 1)
        #expect(transaction.category == "gas")
        #expect(try database.latestSyncTimestamp() == message.timestamp)
    }

    @Test func applyLocalSyncMessagesRejectsUnknownColumns() throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "bogus",
            serializedValue: LocalFirstSyncValue.string("nope").serialized
        )

        #expect(throws: LocalFirstError.invalidLocalWrite("unknown column transactions.bogus")) {
            _ = try database.applyLocalSyncMessages([message])
        }
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

    @Test func uncategorizedAlertCountsOnlyReviewableTransactions() {
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

    @Test func uncategorizedAlertEmptyWhenEverythingCategorized() {
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

    @Test func uncategorizedAlertIncludesOnBudgetTransferToOffBudgetAccount() {
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

    @Test func toBudgetAlertShowsSurplusAndOverbudgetButNotZero() {
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

    @Test func overspendingAlertCountsVisibleNegativeCategoriesInSpendingGroups() {
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

    @Test func budgetAlertsAreOrderedToBudgetThenOverspendingThenUncategorized() {
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
        let budgetDirectory = fileManager.budgetDirectory(fileID: fileID)
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

    private func makeTransaction(
        id: String,
        category: String?,
        payee: String? = nil,
        date: String = "2026-07-03",
        isParent: Bool = false,
        subtransactions: [ActualTransaction] = []
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
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
            """)
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: "ActualistWritableStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: rootURL)
        let fileID = "file-1"
        let budgetDirectory = fileManager.budgetDirectory(fileID: fileID)
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
            name: "Writable Budget",
            state: nil
        )
        _ = try await store.openCachedBudget(budget)
        return store
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
