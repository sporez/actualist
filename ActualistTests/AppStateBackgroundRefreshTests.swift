import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

@MainActor
extension LocalFirstActualStoreTests {
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

    @Test func coldBackgroundRefreshOpensCachedBudgetAndFlushesPendingOutbox() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(expectedMode: nil,
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(pendingCount > 0)
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["cold-open-new"]],
            source: .bankSync,
            notificationID: nil,
            notificationAlreadyAcknowledged: true
        ))

        bundle.store.reset()
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true

        #expect(state.setupPhase == .restoringBudget)
        #expect(!bundle.store.isOpen(budgetID: "group-1"))

        let success = await state.performBackgroundTransactionRefresh()

        #expect(success)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(await transport.messageCounts().contains(pendingCount))
        let run = try #require(state.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message == "Synced budget; no new transactions")
        #expect(state.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["cold-open-new"])
    }

    @Test func refreshSupersededByAForegroundReturnStillPublishesItsNewTransactions() async throws {
        let gate = StubConnectionWaitGate()
        let transport = PendingAlertGatedTransport(gate: gate)
        try await transport.inner.seedServerMessages([
            remoteMessage(index: 0, row: "background-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "background-new", column: "amount", value: .int(-4_200))
        ])
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true
        state.setupPhase = .ready
        state.selectedBudget = bundle.budget

        let background = Task { await state.performBackgroundTransactionRefresh() }
        await gate.waitForEntry()
        // The foreground return reads SQLite before the run records anything.
        await state.prepareBackgroundTransactionNotifications()
        #expect(state.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == nil)
        await gate.release()

        #expect(await background.value)
        #expect(state.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["background-new"])
    }

    @Test func notificationTapPublishesNewTransactionsTheProjectionMissed() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["tapped-new"]],
            source: .remoteSync,
            notificationID: "alert-1",
            notificationAlreadyAcknowledged: true
        ))
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true
        state.setupPhase = .ready
        state.selectedBudget = bundle.budget
        state.selectedTab = .accounts
        #expect(state.settings.pendingNewTransactionIDsByAccount.isEmpty)

        await state.routeToSpendingFromNotification(budgetID: "group-1")

        #expect(state.selectedTab == .spending)
        #expect(state.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["tapped-new"])
    }
}

/// Holds the first pull until released, then serves the seeded server messages.
private actor PendingAlertGatedTransport: ActualSyncTransport {
    let gate: StubConnectionWaitGate
    let inner = RecordingSyncTransport()
    private var calls = 0

    init(gate: StubConnectionWaitGate) {
        self.gate = gate
    }

    func sync(data: Data, token: String) async throws -> Data {
        calls += 1
        if calls == 1 { await gate.wait() }
        return try await inner.sync(data: data, token: token)
    }
}
