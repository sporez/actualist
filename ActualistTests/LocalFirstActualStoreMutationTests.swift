import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
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

    @Test func categorizeTransactionsAtomicallyRefreshesAllAffectedCaches() async throws {
        let store = try await makeOpenedWritableStore()
        let monthBefore = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesBefore = try #require(
            monthBefore.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )
        let drafts = [
            TransactionDraft(
                accountID: "checking",
                date: try makeDate(year: 2026, month: 7, day: 12),
                amountMinorUnits: -725,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            ),
            TransactionDraft(
                accountID: "credit",
                date: try makeDate(year: 2026, month: 7, day: 13),
                amountMinorUnits: -1_275,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: nil,
                notes: nil,
                cleared: false,
                isTransfer: false
            )
        ]
        var createdIDs: [String] = []
        for draft in drafts {
            let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
            createdIDs += result.changed.transactions
        }
        let uncategorized = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let selected = uncategorized.transactions.filter { createdIDs.contains($0.rowID) }
        var didUpdateCount = 0

        let result = try await store.categorizeTransactionsAndRefresh(
            selected,
            categoryID: "groceries",
            budgetID: "group-1"
        ) {
            didUpdateCount += 1
        }

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let credit = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "credit"))
        let uncategorizedAfter = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let monthAfter = try await store.budgetMonth(budgetID: "group-1", selectedMonth: "2026-07")
        let groceriesAfter = try #require(
            monthAfter.month.categoryGroups.flatMap(\.categories).first { $0.id == "groceries" }
        )

        #expect(didUpdateCount == 1)
        #expect(result.ok)
        #expect(result.changed.accounts == ["checking", "credit"])
        #expect(result.changed.months == ["2026-07"])
        #expect(result.changed.transactions == createdIDs.sorted())
        #expect(checking.transactions.first { createdIDs.contains($0.rowID) }?.category == "groceries")
        #expect(credit.transactions.first { createdIDs.contains($0.rowID) }?.category == "groceries")
        #expect(!uncategorizedAfter.transactions.contains { createdIDs.contains($0.rowID) })
        #expect(groceriesAfter.spent == groceriesBefore.spent - 2_000)
    }

    @Test func quickCategorizationSupportsCrossBudgetTransfersInBothDirections() async throws {
        let store = try await makeOpenedWritableStore()
        let outgoing = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 14),
            amountMinorUnits: -2_500,
            payeeID: "xfer-tracking",
            payeeName: "Tracking",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let incoming = TransactionDraft(
            accountID: "tracking",
            date: try makeDate(year: 2026, month: 7, day: 15),
            amountMinorUnits: -3_500,
            payeeID: "xfer-checking",
            payeeName: "Checking",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        _ = try await store.createTransactionAndRefresh(outgoing, budgetID: "group-1") {}
        _ = try await store.createTransactionAndRefresh(incoming, budgetID: "group-1") {}
        let uncategorized = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        let transferRows = uncategorized.transactions.filter { $0.payee == "xfer-tracking" }
        let outgoingBudgetRow = try #require(
            transferRows.first { $0.account == "checking" && $0.amount == -2_500 }
        )
        let incomingBudgetRow = try #require(
            transferRows.first { $0.account == "checking" && $0.amount == 3_500 }
        )

        _ = try await store.categorizeTransactionsAndRefresh(
            [outgoingBudgetRow, incomingBudgetRow],
            categoryID: "groceries",
            budgetID: "group-1"
        ) {}

        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        #expect(checking.transactions.first { $0.rowID == outgoingBudgetRow.rowID }?.category == "groceries")
        #expect(checking.transactions.first { $0.rowID == incomingBudgetRow.rowID }?.category == "groceries")
    }

    @Test func bulkCategorizationAppliesNothingWhenAnySelectionIsUnsupported() async throws {
        let store = try await makeOpenedWritableStore()
        let regularDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 16),
            amountMinorUnits: -800,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        let transferDraft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 16),
            amountMinorUnits: -1_800,
            payeeID: "xfer-credit",
            payeeName: "Credit",
            categoryID: nil,
            notes: nil,
            cleared: false,
            isTransfer: true
        )
        let regularResult = try await store.createTransactionAndRefresh(
            regularDraft,
            budgetID: "group-1"
        ) {}
        _ = try await store.createTransactionAndRefresh(transferDraft, budgetID: "group-1") {}
        let regularID = try #require(regularResult.changed.transactions.first)
        let checking = try #require(store.cachedAccountTransactions(budgetID: "group-1", accountID: "checking"))
        let regular = try #require(checking.transactions.first { $0.rowID == regularID })
        let sameBudgetTransfer = try #require(
            checking.transactions.first { $0.payee == "xfer-credit" && $0.amount == -1_800 }
        )

        await #expect(throws: LocalFirstError.self) {
            _ = try await store.categorizeTransactionsAndRefresh(
                [regular, sameBudgetTransfer],
                categoryID: "groceries",
                budgetID: "group-1"
            ) {}
        }

        let uncategorizedAfter = try await store.uncategorizedTransactions(
            budgetID: "group-1",
            month: "2026-07"
        )
        #expect(uncategorizedAfter.transactions.contains { $0.rowID == regularID })
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

    @Test func appStateRequiresTheSelectedBudgetDatabaseBeforeShowingMainTabs() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()

        #expect(appState.isReadyForMainTabs)

        bundle.store.reset()

        #expect(appState.setupPhase == .ready)
        #expect(!appState.isReadyForMainTabs)
    }

    @Test func failedBudgetSwitchRestoresCurrentBudgetWithoutReplacingMainTabs() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()
        let unavailableBudget = ActualBudget(
            budgetID: nil,
            cloudFileId: nil,
            groupId: nil,
            name: "Unavailable Budget",
            state: nil
        )

        await appState.selectBudgetForCurrentBackend(unavailableBudget)

        #expect(appState.setupPhase == .ready)
        #expect(appState.settings.selectedBudgetID == "group-1")
        #expect(appState.lastErrorMessage == LocalFirstError.missingBudgetFileID.localizedDescription)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(appState.isReadyForMainTabs)
    }

    @Test func encryptedBudgetSelectionPromptsBeforeClosingCurrentBudget() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let appState = try makeAppState(for: bundle)
        await appState.beginForegroundSession()
        let encryptedBudget = ActualBudget(
            budgetID: "file-2",
            cloudFileId: "file-2",
            groupId: "group-2",
            name: "Encrypted Budget",
            state: nil
        )
        bundle.store.remoteFilesByFileID["file-2"] = ActualSyncRemoteFile(
            fileID: "file-2",
            groupID: "group-2",
            name: "Encrypted Budget",
            encryptKeyID: "key-2",
            requiresEncryptionPassword: true
        )

        await appState.selectBudgetForCurrentBackend(encryptedBudget)

        #expect(appState.lastErrorMessage == LocalFirstError.encryptedBudgetRequiresPassword.localizedDescription)
        #expect(appState.settings.selectedBudgetID == "group-1")
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(appState.setupPhase == .ready)
        #expect(appState.isReadyForMainTabs)
    }

    @Test func budgetSwitchKeepsMainTabsReadyWhileReplacementOpens() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 300_000_000)
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try makeAppState(for: bundle)
        appState.selectedBudget = bundle.budget
        appState.setupPhase = .ready
        appState.connectionStatus = .online

        let targetFileID = "file-2"
        let targetDirectory = try bundle.fileManager.budgetDirectory(fileID: targetFileID)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: bundle.fileManager.databaseURL(fileID: "file-1"),
            to: bundle.fileManager.databaseURL(fileID: targetFileID)
        )
        let targetMetadata = LocalFirstBudgetMetadata(
            localBudgetID: targetFileID,
            cloudFileID: targetFileID,
            groupID: "group-2",
            budgetName: "Replacement Budget",
            encryptionKeyID: nil,
            nodeID: "node2"
        )
        try JSONEncoder.actual.encode(targetMetadata).write(
            to: bundle.fileManager.metadataURL(fileID: targetFileID)
        )
        let targetBudget = ActualBudget(
            budgetID: targetFileID,
            cloudFileId: targetFileID,
            groupId: "group-2",
            name: "Replacement Budget",
            state: nil
        )

        let selectionTask = Task {
            await appState.selectBudgetForCurrentBackend(targetBudget)
        }
        for _ in 0..<100 where !appState.isBudgetSwitchInProgress {
            await Task.yield()
        }

        #expect(appState.isBudgetSwitchInProgress)
        #expect(appState.setupPhase == .ready)
        #expect(appState.isReadyForMainTabs)

        await selectionTask.value

        #expect(!appState.isBudgetSwitchInProgress)
        #expect(appState.settings.selectedBudgetID == "group-2")
        #expect(bundle.store.isOpen(budgetID: "group-2"))
        #expect(appState.isReadyForMainTabs)
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

    @Test func structuredAuthenticationFailureShowsReauthenticationBannerState() async throws {
        let transport = AuthenticationFailureSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("expired-token")
        let appState = try makeAppState(for: bundle)

        let succeeded = await appState.refreshLocalFirstData(
            budgetID: "group-1",
            force: true
        )

        #expect(!succeeded)
        #expect(appState.connectionStatus == .offline)
        #expect(appState.requiresReauthentication)
        #expect(
            appState.lastErrorMessage
                == "Your Actual session is no longer valid. Sign in again to resume syncing."
        )
    }

    @Test func successfulReauthenticationClearsExpiredSessionSyncError() async throws {
        let syncTransport = AuthenticationFailureSyncTransport()
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Writable Budget",
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let connectionTransport = StubConnectionTransport(
            files: [remoteFile],
            token: "renewed-token"
        )
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport }
        )
        try bundle.keychain.saveActualSyncToken("expired-token")
        let appState = try makeAppState(for: bundle)

        let expiredRefreshSucceeded = await appState.refreshLocalFirstData(
            budgetID: "group-1",
            force: true
        )

        #expect(!expiredRefreshSucceeded)
        #expect(appState.requiresReauthentication)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError != nil)

        let reauthenticated = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "test-password"
        )

        #expect(reauthenticated)
        #expect(!appState.requiresReauthentication)
        #expect(appState.connectionStatus == .online)
        #expect(appState.lastErrorMessage == nil)
        #expect(bundle.store.syncStatus(budgetID: "group-1")?.lastError == nil)
    }

    @Test func authenticationWithMismatchedCachedBudgetReturnsToBudgetSelection() async throws {
        let remoteFile = ActualSyncRemoteFile(
            fileID: "file-1",
            groupID: "group-1",
            name: "Writable Budget",
            deleted: false,
            encryptKeyID: nil,
            requiresEncryptionPassword: false
        )
        let connectionTransport = StubConnectionTransport(
            files: [remoteFile],
            token: "renewed-token"
        )
        let bundle = try await makeOpenedWritableStoreBundle(
            connectionTransportFactory: { _ in connectionTransport }
        )
        bundle.store.reset()
        let mismatchedMetadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "different-group",
            budgetName: "Writable Budget",
            encryptionKeyID: nil,
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(mismatchedMetadata).write(
            to: bundle.store.fileManager.metadataURL(fileID: "file-1")
        )
        let appState = try makeAppState(for: bundle)

        let authenticated = await appState.saveLocalFirstConnection(
            serverURLString: "https://sync.example",
            password: "test-password"
        )

        #expect(authenticated)
        #expect(appState.hasSyncCredentials)
        #expect(appState.setupPhase == .selectingBudget)
        #expect(!appState.isReadyForMainTabs)
    }

    @Test func appStateRestoresSelectedSQLiteBudgetWithoutSyncCredentials() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        bundle.store.reset()
        let appState = try makeAppState(for: bundle)

        #expect(appState.setupPhase == .restoringBudget)
        #expect(appState.connectionStatus == .offline)
        #expect(appState.cachedSelectedBudgetMonth == nil)

        await appState.beginForegroundSession()

        let loaded = try #require(appState.cachedSelectedBudgetMonth)
        let firstFrameModel = BudgetViewModel(initialMonth: loaded)
        #expect(appState.setupPhase == .ready)
        #expect(appState.connectionStatus == .offline)
        #expect(!firstFrameModel.isLoading)
        #expect(firstFrameModel.budgetMonth != nil)
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
        // Budgeted categories are skipped, even when their template is unsupported.
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

        #expect(utilities.budgeted == 30_000)
        #expect(groceries.budgeted == 50_000)
        #expect(dining.budgeted == 5_000)
    }

    @Test func applyMonthTemplateOverwriteRefusesUnsupportedTemplate() async throws {
        let store = try await makeOpenedWritableStore()
        await #expect(throws: LocalFirstError.self) {
            _ = try await store.applyBudgetTemplateAndRefresh(
                command: .overwrite,
                budgetID: "group-1",
                month: "2026-07"
            ) {}
        }
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

}
