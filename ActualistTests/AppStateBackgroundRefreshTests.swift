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

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(pendingCount > 0)

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
    }
}
