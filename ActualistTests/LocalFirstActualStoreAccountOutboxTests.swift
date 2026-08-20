import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
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
}
