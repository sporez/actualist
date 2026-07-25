import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
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

    @Test func budgetMonthRetainsUncategorizedAlertDrillDownSnapshot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                UPDATE transactions
                SET category = NULL, description = 'coffee'
                WHERE id = 'txn';
                """
        )

        let loaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let cached = try #require(
            bundle.store.cachedUncategorizedTransactions(
                budgetID: "group-1",
                month: "2026-07"
            )
        )

        #expect(loaded.alerts.first(where: { $0.kind == "uncategorizedTransactions" })?.count == 1)
        #expect(cached.transactions.compactMap(\.id) == ["txn"])
        #expect(cached.payeeNames["coffee"] == "Coffee Shop")
        #expect(cached.categoryGroups.flatMap(\.options).contains { $0.id == "groceries" })
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

}
