import Foundation
import Testing
@testable import Actualist

@MainActor
struct ActualDataStoreTests {
    @Test func accountDecodesMissingBankSyncLinkedAsFalse() throws {
        let data = Data("""
        {
          "id": "checking",
          "name": "Checking",
          "offbudget": false,
          "closed": false
        }
        """.utf8)

        let account = try JSONDecoder.actual.decode(ActualAccount.self, from: data)

        #expect(account.bankSyncLinked == false)
    }

    @Test func appSettingsRoundTripsBackgroundRefreshState() throws {
        let wakeDate = Date(timeIntervalSinceReferenceDate: 10)
        let finishDate = Date(timeIntervalSinceReferenceDate: 20)
        let scheduleDate = Date(timeIntervalSinceReferenceDate: 30)
        let earliestBeginDate = Date(timeIntervalSinceReferenceDate: 40)
        let settings = AppSettings(
            serverURLString: "http://localhost:5007/v1",
            selectedBudgetID: "budget",
            selectedBudgetName: "Budget",
            accountOrderByBudgetID: ["budget": ["savings", "checking"]],
            backgroundTransactionRefreshEnabled: true,
            backgroundRefreshDebug: BackgroundRefreshDebugInfo(
                totalWakeCount: 2,
                recentRuns: [
                    BackgroundRefreshDebugRun(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                        wakeDate: wakeDate,
                        completionDate: finishDate,
                        succeeded: true,
                        message: "Checked 1 linked accounts; found 0 new transactions"
                    )
                ],
                totalScheduleAttemptCount: 3,
                recentScheduleAttempts: [
                    BackgroundRefreshScheduleAttempt(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                        date: scheduleDate,
                        earliestBeginDate: earliestBeginDate,
                        succeeded: true,
                        message: "Scheduled background refresh"
                    )
                ]
            ),
            pendingNewTransactionIDsByAccount: ["budget|checking": ["txn1", "txn2"]]
        )

        let data = try JSONEncoder.actual.encode(settings)
        let decoded = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(decoded.backgroundTransactionRefreshEnabled)
        #expect(decoded.backgroundRefreshDebug.wakeCount == 2)
        #expect(decoded.backgroundRefreshDebug.recentRuns.count == 1)
        #expect(decoded.backgroundRefreshDebug.recentRuns.first?.wakeDate == wakeDate)
        #expect(decoded.backgroundRefreshDebug.recentRuns.first?.completionDate == finishDate)
        #expect(decoded.backgroundRefreshDebug.recentRuns.first?.succeeded == true)
        #expect(decoded.backgroundRefreshDebug.scheduleAttemptCount == 3)
        #expect(decoded.backgroundRefreshDebug.recentScheduleAttempts.count == 1)
        #expect(decoded.backgroundRefreshDebug.recentScheduleAttempts.first?.date == scheduleDate)
        #expect(decoded.backgroundRefreshDebug.recentScheduleAttempts.first?.earliestBeginDate == earliestBeginDate)
        #expect(decoded.backgroundRefreshDebug.recentScheduleAttempts.first?.succeeded == true)
        #expect(decoded.pendingNewTransactionIDsByAccount["budget|checking"] == ["txn1", "txn2"])
        #expect(decoded.accountOrderByBudgetID["budget"] == ["savings", "checking"])
    }

    @Test func appSettingsDecodesMissingAccountOrderAsEmpty() throws {
        let data = Data("""
        {
          "serverURLString": "http://localhost:5007/v1"
        }
        """.utf8)

        let decoded = try JSONDecoder.actual.decode(AppSettings.self, from: data)

        #expect(decoded.accountOrderByBudgetID.isEmpty)
    }

    @Test func accountOrderPreferenceAppliesSavedOrderAndAppendsUnknownAccounts() {
        let accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false),
            ActualAccount(id: "travel", name: "Travel", offbudget: true, closed: false)
        ]

        let ordered = AccountOrderPreference.ordered(
            accounts,
            preferredIDs: ["missing", "savings", "checking", "savings"]
        )

        #expect(ordered.map(\.id) == ["savings", "checking", "travel"])
    }

    @Test func accountsWithBalancesCachesAndComposesDisplays() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountsWithBalances(budgetID: "b")

        let displays = store.accountDisplays(budgetID: "b")
        #expect(displays.count == 2)
        #expect(displays.first(where: { $0.account.id == "checking" })?.balance == 1_000)
        #expect(displays.first(where: { $0.account.id == "savings" })?.balance == 5_000)
    }

    @Test func accountRefreshFailureKeepsCachedAccountDisplays() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountsWithBalances(budgetID: "b")
        await client.setFailAccounts(true)
        try await store.refreshAccountsWithBalances(budgetID: "b")

        let displays = store.accountDisplays(budgetID: "b")
        #expect(displays.count == 2)
        #expect(displays.first(where: { $0.account.id == "checking" })?.balance == 1_000)
        #expect(displays.first(where: { $0.account.id == "savings" })?.balance == 5_000)
        #expect(await client.callCount(.accounts) == 2)
    }

    @Test func accountRefreshFailureWithoutCacheThrows() async throws {
        let client = FakeAPIClient(failAccounts: true)
        let store = ActualDataStore { client }

        await #expect(throws: ActualAPIError.self) {
            try await store.refreshAccountsWithBalances(budgetID: "b")
        }
        #expect(store.accountDisplays(budgetID: "b").isEmpty)
    }

    @Test func createAccountRefreshesAccountsAndBalances() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountsWithBalances(budgetID: "b")
        try await store.createAccountAndRefresh(
            budgetID: "b",
            name: "Travel Card",
            offbudget: true
        )

        let created = try #require(await client.lastCreatedAccount())
        #expect(created.name == "Travel Card")
        #expect(created.offbudget == true)
        #expect(await client.callCount(.createAccount) == 1)
        #expect(await client.callCount(.accounts) == 2)

        let displays = store.accountDisplays(budgetID: "b")
        let added = try #require(displays.first { $0.account.name == "Travel Card" })
        #expect(added.account.offbudget == true)
        #expect(added.balance == 0)
    }

    @Test func snapshotRoundTripRestoresCachedBudgetData() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountsWithBalances(budgetID: "b")
        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")

        let encoded = try JSONEncoder.actual.encode(store.snapshot())
        let decoded = try JSONDecoder.actual.decode(ActualDataStoreSnapshot.self, from: encoded)
        let restored = ActualDataStore { nil }

        restored.restore(decoded)

        let displays = restored.accountDisplays(budgetID: "b")
        #expect(displays.count == 2)
        #expect(displays.first(where: { $0.account.id == "checking" })?.balance == 1_000)
        #expect(displays.first(where: { $0.account.id == "savings" })?.balance == 5_000)
        #expect(restored.hasCachedBudgetData(budgetID: "b"))

        let cached = try #require(restored.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.map(\.id) == ["t1"])
        #expect(cached.categoryNames["groceries"] == "Groceries")
        #expect(cached.payeeNames["store"] == "Corner Store")
        #expect(cached.transferPayeeIDs.contains("transfer-checking"))
    }

    @Test func ensureReferenceDataServesCacheWithinTTL() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.ensureCategories(budgetID: "b")
        try await store.ensureCategories(budgetID: "b")

        #expect(await client.callCount(.categories) == 1)
    }

    @Test func concurrentRefreshesAreCoalescedIntoOneRequest() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        async let first: Void = store.refreshAccounts(budgetID: "b")
        async let second: Void = store.refreshAccounts(budgetID: "b")
        _ = try await (first, second)

        #expect(await client.callCount(.accounts) == 1)
    }

    @Test func refreshAccountTransactionsComposesCachedSnapshot() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.count == 1)
        #expect(cached.balance == 1_000)
        #expect(cached.categoryNames["groceries"] == "Groceries")
        #expect(cached.payeeNames["store"] == "Corner Store")
        #expect(cached.transferPayeeIDs.contains("transfer-checking"))
    }

    @Test func refreshAccountTransactionsFiltersStandaloneSplitChildren() async throws {
        let parent = Self.transaction(id: "parent", date: "2026-06-15")
        let child = ActualTransaction(
            id: "child",
            account: "checking",
            date: "2026-06-15",
            amount: -500,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: "groceries",
            notes: nil,
            cleared: .bool(true),
            isChild: true,
            parentID: "parent"
        )
        let client = FakeAPIClient(transactionResponses: [[parent, child]])
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.map(\.id) == ["parent"])
    }

    @Test func refreshAccountTransactionsUsesRecentOpenWindow() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")

        let windows = await client.transactionWindows()
        #expect(windows == ["2026-03-19..."])
    }

    @Test func loadOlderTransactionsFetchesPreviousWindowAndExtendsCachedRange() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "recent", date: "2026-06-15")],
                [Self.transaction(id: "older", date: "2026-02-15")]
            ]
        )
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        try await store.loadOlderTransactions(budgetID: "b", accountID: "checking")

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.map(\.id) == ["recent", "older"])
        #expect(cached.reachedEnd == false)

        let windows = await client.transactionWindows()
        #expect(windows == [
            "2026-03-19...",
            "2025-12-19...2026-03-18"
        ])
    }

    @Test func loadOlderTransactionsMarksEndOnEmptyDeltaWithoutRefreshingBalance() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "recent", date: "2026-06-15")],
                []
            ]
        )
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let balanceCallsAfterRefresh = await client.callCount(.balance)
        try await store.loadOlderTransactions(budgetID: "b", accountID: "checking")

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.reachedEnd)
        #expect(cached.balance == 1_000)
        #expect(await client.callCount(.balance) == balanceCallsAfterRefresh)
    }

    @Test func searchAccountTransactionsReturnsDisplaySnapshotWithoutMutatingLoadedPage() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "loaded", date: "2026-06-15")]
            ],
            searchTransactionResponses: [
                [Self.transaction(id: "search", date: "2026-06-14")]
            ]
        )
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let results = try await store.searchAccountTransactions(
            budgetID: "b",
            accountID: "checking",
            query: "corner",
            limit: 25,
            offset: 0
        )

        #expect(results.transactions.map(\.id) == ["search"])
        #expect(results.categoryNames["groceries"] == "Groceries")
        #expect(results.payeeNames["store"] == "Corner Store")
        #expect(results.transferPayeeIDs.contains("transfer-checking"))
        #expect(results.reachedEnd)
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["loaded"])
        #expect(await client.callCount(.searchTransactions) == 1)
    }

    @Test func refreshSpendingTransactionsComposesAccountDisplaySnapshot() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [
                    Self.transaction(id: "checking", accountID: "checking", date: "2026-06-15"),
                    Self.transaction(id: "savings", accountID: "savings", date: "2026-06-14")
                ]
            ]
        )
        let store = ActualDataStore { client }

        try await store.refreshSpendingTransactions(budgetID: "b")

        let cached = try #require(store.cachedSpendingTransactions(budgetID: "b"))
        #expect(cached.transactions.map(\.id) == ["checking", "savings"])
        #expect(cached.balance == nil)
        #expect(cached.accountNames["checking"] == "Checking")
        #expect(cached.accountNames["savings"] == "Savings")
        #expect(cached.categoryNames["groceries"] == "Groceries")
        #expect(cached.payeeNames["store"] == "Corner Store")
    }

    @Test func searchSpendingTransactionsReturnsDisplaySnapshotWithoutMutatingLoadedPage() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "loaded", accountID: "checking", date: "2026-06-15")]
            ],
            searchTransactionResponses: [
                [Self.transaction(id: "search", accountID: "savings", date: "2026-06-14")]
            ]
        )
        let store = ActualDataStore { client }

        try await store.refreshSpendingTransactions(budgetID: "b")
        let results = try await store.searchSpendingTransactions(
            budgetID: "b",
            query: "corner",
            limit: 25,
            offset: 0
        )

        #expect(results.transactions.map(\.id) == ["search"])
        #expect(results.accountNames["savings"] == "Savings")
        #expect(results.reachedEnd)
        #expect(store.cachedSpendingTransactions(budgetID: "b")?.transactions.map(\.id) == ["loaded"])
        #expect(await client.callCount(.searchTransactions) == 1)
    }

    @Test func loadOlderSpendingTransactionsFetchesPreviousWindowAndExtendsCachedRange() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "recent", accountID: "checking", date: "2026-06-15")],
                [Self.transaction(id: "older", accountID: "savings", date: "2026-02-15")]
            ]
        )
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshSpendingTransactions(budgetID: "b")
        try await store.loadOlderSpendingTransactions(budgetID: "b")

        let cached = try #require(store.cachedSpendingTransactions(budgetID: "b"))
        #expect(cached.transactions.map(\.id) == ["recent", "older"])
        #expect(cached.reachedEnd == false)

        let windows = await client.transactionWindows()
        #expect(windows == [
            "2026-03-19...",
            "2025-12-19...2026-03-18"
        ])
    }

    @Test func writeInvalidationRefreshesLoadedSpendingTransactions() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "before", accountID: "checking", date: "2026-06-15")],
                [Self.transaction(id: "account-after", accountID: "checking", date: "2026-06-14")],
                [Self.transaction(id: "spending-after", accountID: "savings", date: "2026-06-13")]
            ]
        )
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshSpendingTransactions(budgetID: "b")
        try await store.applyInvalidation(
            ChangedResources(accounts: ["checking"], months: [], transactions: ["before"]),
            budgetID: "b"
        )

        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["account-after"])
        #expect(store.cachedSpendingTransactions(budgetID: "b")?.transactions.map(\.id) == ["spending-after"])
    }

    @Test func uncategorizedTransactionsReturnsDisplaySnapshot() async throws {
        let client = FakeAPIClient(
            uncategorizedTransactionResponses: [
                [
                    Self.transaction(id: "uncategorized", date: "2026-06-14", category: nil),
                    Self.transaction(id: "transfer", date: "2026-06-14", payee: "transfer-checking", category: nil)
                ]
            ]
        )
        let store = ActualDataStore { client }

        let results = try await store.uncategorizedTransactions(budgetID: "b", month: "2026-06")

        #expect(results.transactions.map(\.id) == ["uncategorized"])
        #expect(results.accountNames["checking"] == "Checking")
        #expect(results.payeeNames["store"] == "Corner Store")
        #expect(results.transferPayeeIDs.contains("transfer-checking"))
        #expect(results.categoryGroups.flatMap(\.options).map(\.id) == ["groceries"])
        #expect(await client.callCount(.uncategorizedTransactions) == 1)
    }

    @Test func budgetMonthCorrectsUncategorizedAlertCountForTransfers() async throws {
        let client = FakeAPIClient(
            uncategorizedTransactionResponses: [
                [
                    Self.transaction(id: "uncategorized-1", date: "2026-06-14", category: nil),
                    Self.transaction(id: "uncategorized-2", date: "2026-06-15", category: nil),
                    Self.transaction(id: "uncategorized-3", date: "2026-06-16", category: nil),
                    Self.transaction(id: "transfer", date: "2026-06-17", payee: "transfer-checking", category: nil)
                ]
            ],
            budgetMonthAlertsResponse: APIBudgetMonthAlerts(
                month: "2026-06",
                alerts: [
                    APIBudgetMonthAlert(
                        kind: "uncategorizedTransactions",
                        severity: "warning",
                        title: "Uncategorized transactions",
                        amount: nil,
                        count: 4,
                        actionTitle: "Review"
                    )
                ]
            )
        )
        let store = ActualDataStore { client }

        let loaded = try await store.budgetMonth(budgetID: "b", selectedMonth: "2026-06")

        #expect(loaded.alerts.first?.kind == "uncategorizedTransactions")
        #expect(loaded.alerts.first?.count == 3)
        #expect(await client.callCount(.uncategorizedTransactions) == 1)
    }

    @Test func categorizeTransactionInvalidatesAffectedAccountAndMonth() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "after", date: "2026-06-15")]
            ]
        )
        let store = ActualDataStore { client }
        let transaction = Self.transaction(id: "uncategorized", date: "2026-06-14", category: nil)

        let result = try await store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "groceries",
            budgetID: "b"
        ) {}

        #expect(result.ok)
        #expect(await client.callCount(.updateTransactionCategory) == 1)
        #expect(await client.lastCategorizedTransactionID() == "uncategorized")
        #expect(await client.lastCategorizedCategoryID() == "groceries")
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["after"])
        #expect(await client.callCount(.budgetMonth) >= 1)
    }

    @Test func bankSyncInvalidatesAndRefetchesAccount() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "before", date: "2026-06-15")],
                [Self.transaction(id: "after", date: "2026-06-16")]
            ]
        )
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let synced = try await store.syncBankAccountAndRefresh(budgetID: "b", accountID: "checking")

        #expect(synced?.transactions.map(\.id) == ["after"])
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["after"])
        #expect(await client.callCount(.syncBankAccount) == 1)
        #expect(await client.callCount(.transactions) == 2)
        #expect(await client.callCount(.balance) == 2)
    }

    @Test func backgroundBankSyncSeedsBaselineWithoutNewTransactionIDs() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "first", date: "2026-06-15")]
            ]
        )
        let store = ActualDataStore { client }
        let account = ActualAccount(
            id: "checking",
            name: "Checking",
            offbudget: false,
            closed: false,
            bankSyncLinked: true
        )

        let result = try await store.syncBankAccountAndFindNewTransactions(
            budgetID: "b",
            account: account
        )

        #expect(result.newTransactionIDs.isEmpty)
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["first"])
        #expect(await client.callCount(.syncBankAccount) == 1)
    }

    @Test func backgroundBankSyncReportsNewTransactionIDsAfterBaseline() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "before", date: "2026-06-15")],
                [
                    Self.transaction(id: "after", date: "2026-06-16"),
                    Self.transaction(id: "before", date: "2026-06-15")
                ]
            ]
        )
        let store = ActualDataStore { client }
        let account = ActualAccount(
            id: "checking",
            name: "Checking",
            offbudget: false,
            closed: false,
            bankSyncLinked: true
        )

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let result = try await store.syncBankAccountAndFindNewTransactions(
            budgetID: "b",
            account: account
        )

        #expect(result.newTransactionIDs == ["after"])
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["after", "before"])
        #expect(await client.callCount(.syncBankAccount) == 1)
        #expect(await client.callCount(.transactions) == 2)
    }

    @Test func reconcileInvalidatesAndRefetchesAccountWhenMatched() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "before", date: "2026-06-15")],
                [Self.transaction(id: "after", date: "2026-06-16")]
            ],
            reconciliationResult: APIAccountReconciliationResult(
                accountID: "checking",
                cutoffDate: "2026-06-21",
                statementBalance: 1_000,
                clearedBalance: 1_000,
                difference: 0,
                reconciled: true,
                updated: ["before"]
            )
        )
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let result = try await store.reconcileAccountAndRefresh(
            budgetID: "b",
            accountID: "checking",
            statementBalance: 1_000
        )

        #expect(result.reconciled)
        #expect(await client.lastReconciliationRequest() == FakeAPIClient.ReconciliationRequest(
            budgetID: "b",
            accountID: "checking",
            statementBalance: 1_000
        ))
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["after"])
        #expect(await client.callCount(.reconcileAccount) == 1)
        #expect(await client.callCount(.transactions) == 2)
        #expect(await client.callCount(.balance) == 2)
    }

    @Test func reconcileMismatchDoesNotInvalidateOrRefetchAccount() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "loaded", date: "2026-06-15")]
            ],
            reconciliationResult: APIAccountReconciliationResult(
                accountID: "checking",
                cutoffDate: "2026-06-21",
                statementBalance: 1_250,
                clearedBalance: 1_000,
                difference: 250,
                reconciled: false,
                updated: []
            )
        )
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        let callsBeforeReconcile = await client.callCount(.transactions)
        let result = try await store.reconcileAccountAndRefresh(
            budgetID: "b",
            accountID: "checking",
            statementBalance: 1_250
        )

        #expect(result.reconciled == false)
        #expect(result.difference == 250)
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking")?.transactions.map(\.id) == ["loaded"])
        #expect(await client.callCount(.reconcileAccount) == 1)
        #expect(await client.callCount(.transactions) == callsBeforeReconcile)
    }

    @Test func writeInvalidationReplacesPreservedLoadedRange() async throws {
        let client = FakeAPIClient(
            transactionResponses: [
                [Self.transaction(id: "deleted", date: "2026-06-15")],
                [Self.transaction(id: "survivor", date: "2026-06-14")]
            ]
        )
        let store = ActualDataStore(
            clientProvider: { client },
            now: { Self.date("2026-06-17") }
        )

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        try await store.applyInvalidation(
            ChangedResources(accounts: ["checking"], months: [], transactions: ["deleted"]),
            budgetID: "b"
        )

        let cached = try #require(store.cachedAccountTransactions(budgetID: "b", accountID: "checking"))
        #expect(cached.transactions.map(\.id) == ["survivor"])

        let windows = await client.transactionWindows()
        #expect(windows == [
            "2026-03-19...",
            "2026-03-19..."
        ])
    }

    @Test func assignmentInvalidatesAndRefetchesAffectedMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        // Warm the month cache.
        _ = try await store.budgetMonth(budgetID: "b", selectedMonth: "2026-06")
        let monthCallsAfterWarm = await client.callCount(.budgetMonth)

        let loaded = try await store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 5_000,
            budgetID: "b",
            month: "2026-06",
            didAssign: {}
        )

        #expect(loaded.selectedMonth == "2026-06")
        #expect(await client.callCount(.updateBudgetMonthCategory) == 1)
        // The month was invalidated and refetched after the write.
        #expect(await client.callCount(.budgetMonth) > monthCallsAfterWarm)
    }

    @Test func categoryTransferInvalidatesAndRefetchesAffectedMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        // Warm the month cache.
        _ = try await store.budgetMonth(budgetID: "b", selectedMonth: "2026-06")
        let monthCallsAfterWarm = await client.callCount(.budgetMonth)

        let loaded = try await store.moveMoneyAndRefresh(
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries",
                toCategoryID: nil,
                amount: 2_500
            ),
            budgetID: "b",
            month: "2026-06",
            didMove: {}
        )

        #expect(loaded.selectedMonth == "2026-06")
        #expect(await client.callCount(.createCategoryTransfer) == 1)
        #expect(await client.lastCategoryTransfer() == BudgetMoveMoneyCommand(
            fromCategoryID: "groceries",
            toCategoryID: nil,
            amount: 2_500
        ))
        // The month was invalidated and refetched after the write.
        #expect(await client.callCount(.budgetMonth) > monthCallsAfterWarm)
    }

    @Test func templateApplyInvalidatesAndRefetchesAffectedMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        // Warm the month cache.
        _ = try await store.budgetMonth(budgetID: "b", selectedMonth: "2026-06")
        let monthCallsAfterWarm = await client.callCount(.budgetMonth)

        let loaded = try await store.applyBudgetTemplateAndRefresh(
            command: .category("groceries"),
            budgetID: "b",
            month: "2026-06",
            didApply: {}
        )

        #expect(loaded.selectedMonth == "2026-06")
        #expect(await client.callCount(.applyBudgetTemplate) == 1)
        #expect(await client.lastTemplateCommand() == .category("groceries"))
        // The month was invalidated and refetched after the write.
        #expect(await client.callCount(.budgetMonth) > monthCallsAfterWarm)
    }

    @Test func createTransactionInvalidatesAffectedAccountAndMonth() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        let draft = TransactionDraft(
            accountID: "checking",
            date: Self.june2026,
            amountMinorUnits: -1_500,
            payeeID: "store",
            payeeName: "Corner Store",
            categoryID: "groceries",
            notes: nil,
            cleared: true,
            isTransfer: false
        )

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "b") {}

        #expect(result.ok)
        #expect(await client.callCount(.createTransaction) == 1)
        // Affected account transactions + month were refetched into the cache.
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") != nil)
        #expect(await client.callCount(.transactions) >= 1)
        #expect(await client.callCount(.budgetMonth) >= 1)
    }

    @Test func resetClearsAllCaches() async throws {
        let client = FakeAPIClient()
        let store = ActualDataStore { client }

        try await store.refreshAccountTransactions(budgetID: "b", accountID: "checking")
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") != nil)

        store.reset()
        #expect(store.cachedAccountTransactions(budgetID: "b", accountID: "checking") == nil)
        #expect(store.accountDisplays(budgetID: "b").isEmpty)
    }

    private static var june2026: Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 6, day: 15).date!
    }

    private static func date(_ value: String) -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: parts[0],
            month: parts[1],
            day: parts[2]
        ).date!
    }

    fileprivate nonisolated static func transaction(
        id: String,
        accountID: String = "checking",
        date: String,
        payee: String = "store",
        category: String? = "groceries"
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: accountID,
            date: date,
            amount: -1_500,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: category,
            notes: nil,
            cleared: .bool(true)
        )
    }
}

actor FakeAPIClient: ActualAPIClientProtocol {
    struct ReconciliationRequest: Equatable {
        let budgetID: String
        let accountID: String
        let statementBalance: Int
    }

    enum Method {
        case accounts, createAccount, balance, transactions, searchTransactions, uncategorizedTransactions, categories, payees, budgets
        case budgetMonths, budgetMonth, budgetMonthAlerts, updateBudgetMonthCategory
        case createCategoryTransfer, applyBudgetTemplate
        case syncBankAccount, reconcileAccount
        case createTransaction, updateTransaction, updateTransactionCategory, deleteTransaction, runTransactionRules
    }

    private var counts: [Method: Int] = [:]
    private var transactionResponses: [[ActualTransaction]]
    private var searchTransactionResponses: [[ActualTransaction]]
    private var uncategorizedTransactionResponses: [[ActualTransaction]]
    private var requestedTransactionWindows: [(since: Date, until: Date?)] = []
    private var createdAccounts: [ActualAccount] = []
    private var recordedCategoryTransfer: BudgetMoveMoneyCommand?
    private var recordedTemplateCommand: BudgetTemplateCommand?
    private var recordedReconciliationRequest: ReconciliationRequest?
    private var recordedCategorizedTransactionID: String?
    private var recordedCategorizedCategoryID: String?
    private var reconciliationResult: APIAccountReconciliationResult
    private var failAccounts: Bool
    private var budgetMonthAlertsResponse: APIBudgetMonthAlerts

    init(
        transactionResponses: [[ActualTransaction]] = [],
        searchTransactionResponses: [[ActualTransaction]] = [],
        uncategorizedTransactionResponses: [[ActualTransaction]] = [],
        budgetMonthAlertsResponse: APIBudgetMonthAlerts = APIBudgetMonthAlerts(month: "2026-06", alerts: []),
        failAccounts: Bool = false,
        reconciliationResult: APIAccountReconciliationResult = APIAccountReconciliationResult(
            accountID: "checking",
            cutoffDate: "2026-06-21",
            statementBalance: 1_000,
            clearedBalance: 1_000,
            difference: 0,
            reconciled: true,
            updated: []
        )
    ) {
        self.transactionResponses = transactionResponses
        self.searchTransactionResponses = searchTransactionResponses
        self.uncategorizedTransactionResponses = uncategorizedTransactionResponses
        self.failAccounts = failAccounts
        self.reconciliationResult = reconciliationResult
        self.budgetMonthAlertsResponse = budgetMonthAlertsResponse
    }

    func callCount(_ method: Method) -> Int {
        counts[method] ?? 0
    }

    func transactionWindows() -> [String] {
        requestedTransactionWindows.map { window in
            if let until = window.until {
                return "\(Self.formattedDate(window.since))...\(Self.formattedDate(until))"
            }
            return "\(Self.formattedDate(window.since))..."
        }
    }

    func lastCategoryTransfer() -> BudgetMoveMoneyCommand? {
        recordedCategoryTransfer
    }

    func lastTemplateCommand() -> BudgetTemplateCommand? {
        recordedTemplateCommand
    }

    func lastReconciliationRequest() -> ReconciliationRequest? {
        recordedReconciliationRequest
    }

    func lastCreatedAccount() -> ActualAccount? {
        createdAccounts.last
    }

    func lastCategorizedTransactionID() -> String? {
        recordedCategorizedTransactionID
    }

    func lastCategorizedCategoryID() -> String? {
        recordedCategorizedCategoryID
    }

    func setFailAccounts(_ failAccounts: Bool) {
        self.failAccounts = failAccounts
    }

    private func record(_ method: Method) {
        counts[method, default: 0] += 1
    }

    func budgets() async throws -> [ActualBudget] {
        record(.budgets)
        return [ActualBudget(budgetID: "b", cloudFileId: nil, groupId: nil, name: "Budget", state: nil)]
    }

    func accounts(budgetID: String) async throws -> [ActualAccount] {
        record(.accounts)
        await Task.yield()
        if failAccounts {
            throw ActualAPIError.transport(nil)
        }

        return [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false, bankSyncLinked: true),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ] + createdAccounts
    }

    func createAccount(
        budgetID: String,
        name: String,
        offbudget: Bool
    ) async throws -> APIGeneralResponseMessage {
        record(.createAccount)
        createdAccounts.append(
            ActualAccount(
                id: "created-\(createdAccounts.count + 1)",
                name: name,
                offbudget: offbudget,
                closed: false
            )
        )
        return APIGeneralResponseMessage(message: "Account created")
    }

    func balance(budgetID: String, accountID: String) async throws -> Int {
        record(.balance)
        if accountID == "checking" {
            return 1_000
        }
        if accountID == "savings" {
            return 5_000
        }
        return 0
    }

    func syncBankAccount(
        budgetID: String,
        accountID: String
    ) async throws -> APIGeneralResponseMessage {
        record(.syncBankAccount)
        return APIGeneralResponseMessage(message: "Bank sync started")
    }

    func reconcileAccount(
        budgetID: String,
        accountID: String,
        statementBalance: Int
    ) async throws -> APIAccountReconciliationResult {
        record(.reconcileAccount)
        recordedReconciliationRequest = ReconciliationRequest(
            budgetID: budgetID,
            accountID: accountID,
            statementBalance: statementBalance
        )
        return reconciliationResult
    }

    func transactions(
        budgetID: String,
        accountID: String,
        since: Date,
        until: Date?
    ) async throws -> [ActualTransaction] {
        record(.transactions)
        requestedTransactionWindows.append((since: since, until: until))
        if !transactionResponses.isEmpty {
            return transactionResponses.removeFirst()
        }

        return [
            ActualDataStoreTests.transaction(id: "t1", accountID: accountID, date: "2026-06-15")
        ]
    }

    func transactions(
        budgetID: String,
        since: Date,
        until: Date?
    ) async throws -> [ActualTransaction] {
        record(.transactions)
        requestedTransactionWindows.append((since: since, until: until))
        if !transactionResponses.isEmpty {
            return transactionResponses.removeFirst()
        }

        return [
            ActualDataStoreTests.transaction(id: "checking-t1", accountID: "checking", date: "2026-06-15"),
            ActualDataStoreTests.transaction(id: "savings-t1", accountID: "savings", date: "2026-06-14")
        ]
    }

    func searchTransactions(
        budgetID: String,
        accountID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [ActualTransaction] {
        record(.searchTransactions)
        if !searchTransactionResponses.isEmpty {
            return searchTransactionResponses.removeFirst()
        }

        return [
            ActualDataStoreTests.transaction(id: "search", accountID: accountID, date: "2026-06-15")
        ]
    }

    func searchTransactions(
        budgetID: String,
        query: String,
        limit: Int,
        offset: Int
    ) async throws -> [ActualTransaction] {
        record(.searchTransactions)
        if !searchTransactionResponses.isEmpty {
            return searchTransactionResponses.removeFirst()
        }

        return [
            ActualDataStoreTests.transaction(id: "search", accountID: "savings", date: "2026-06-15")
        ]
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> [ActualTransaction] {
        record(.uncategorizedTransactions)
        if !uncategorizedTransactionResponses.isEmpty {
            return uncategorizedTransactionResponses.removeFirst()
        }

        return [
            ActualDataStoreTests.transaction(id: "uncategorized", date: "\(month)-15", category: nil)
        ]
    }

    func categories(budgetID: String) async throws -> [ActualCategory] {
        record(.categories)
        return [ActualCategory(id: "groceries", name: "Groceries", isIncome: false, hidden: false, groupID: "bills")]
    }

    func payees(budgetID: String) async throws -> [ActualPayee] {
        record(.payees)
        return [
            ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil),
            ActualPayee(id: "transfer-checking", name: "Checking", category: nil, transferAccount: "checking")
        ]
    }

    func budgetMonths(budgetID: String) async throws -> [String] {
        record(.budgetMonths)
        return ["2026-05", "2026-06"]
    }

    func budgetMonth(budgetID: String, month: String) async throws -> BudgetMonth {
        record(.budgetMonth)
        return try JSONDecoder().decode(BudgetMonth.self, from: Self.budgetMonthJSON)
    }

    func budgetMonthAlerts(budgetID: String, month: String) async throws -> APIBudgetMonthAlerts {
        record(.budgetMonthAlerts)
        return budgetMonthAlertsResponse
    }

    func updateBudgetMonthCategory(
        budgetID: String,
        month: String,
        categoryID: String,
        budgeted: Int
    ) async throws -> APIGeneralResponseMessage {
        record(.updateBudgetMonthCategory)
        return APIGeneralResponseMessage(message: "ok")
    }

    func createCategoryTransfer(
        budgetID: String,
        month: String,
        fromCategoryID: String?,
        toCategoryID: String?,
        amount: Int
    ) async throws -> APIGeneralResponseMessage {
        record(.createCategoryTransfer)
        recordedCategoryTransfer = BudgetMoveMoneyCommand(
            fromCategoryID: fromCategoryID,
            toCategoryID: toCategoryID,
            amount: amount
        )
        return APIGeneralResponseMessage(message: "ok")
    }

    func applyBudgetTemplate(
        budgetID: String,
        month: String,
        command: BudgetTemplateCommand
    ) async throws -> APIBudgetTemplateApplyResult {
        record(.applyBudgetTemplate)
        recordedTemplateCommand = command
        return APIBudgetTemplateApplyResult(
            type: "template",
            message: "ok",
            pre: nil,
            sticky: nil
        )
    }

    func createTransaction(budgetID: String, draft: TransactionDraft) async throws -> APITransactionBatchUpdateResult {
        record(.createTransaction)
        return try Self.emptyBatchResult()
    }

    func updateTransaction(
        budgetID: String,
        transactionID: String,
        draft: TransactionDraft
    ) async throws -> APITransactionBatchUpdateResult {
        record(.updateTransaction)
        return try Self.emptyBatchResult()
    }

    func updateTransactionCategory(
        budgetID: String,
        transaction: ActualTransaction,
        categoryID: String
    ) async throws -> APITransactionBatchUpdateResult {
        record(.updateTransactionCategory)
        recordedCategorizedTransactionID = transaction.id
        recordedCategorizedCategoryID = categoryID
        return try Self.emptyBatchResult()
    }

    func deleteTransaction(
        budgetID: String,
        transaction: ActualTransaction
    ) async throws -> APITransactionBatchUpdateResult {
        record(.deleteTransaction)
        return try Self.emptyBatchResult()
    }

    func runTransactionRules(budgetID: String, draft: TransactionDraft) async throws -> TransactionRulePreview {
        record(.runTransactionRules)
        return TransactionRulePreview(categoryID: nil, notes: nil)
    }

    private static func emptyBatchResult() throws -> APITransactionBatchUpdateResult {
        try JSONDecoder().decode(APITransactionBatchUpdateResult.self, from: "{}".data(using: .utf8)!)
    }

    private static func formattedDate(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static let budgetMonthJSON = """
    {
      "month": "2026-06",
      "incomeAvailable": 0,
      "lastMonthOverspent": 0,
      "forNextMonth": 0,
      "totalBudgeted": 0,
      "toBudget": 0,
      "fromLastMonth": 0,
      "totalIncome": 0,
      "totalSpent": 0,
      "totalBalance": 0,
      "categoryGroups": [
        {
          "id": "bills",
          "name": "Bills",
          "is_income": false,
          "hidden": false,
          "budgeted": 0,
          "spent": 0,
          "balance": 0,
          "categories": [
            {
              "id": "groceries",
              "name": "Groceries",
              "is_income": false,
              "hidden": false,
              "group_id": "bills",
              "budgeted": 0,
              "spent": 0,
              "balance": 2500,
              "carryover": false
            }
          ]
        }
      ]
    }
    """.data(using: .utf8)!
}
