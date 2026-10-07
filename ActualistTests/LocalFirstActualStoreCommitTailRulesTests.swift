import Foundation
import Testing
@testable import Actualist

/// The rules and payee refresh of a learning write runs inside the durable
/// tail, so a superseded or failed refresh never turns a commit into a failure
/// (concurrency remediation 0.2, audit CA-01).
@MainActor
struct LocalFirstActualStoreCommitTailRulesTests {
    private let support = LocalFirstActualStoreTests()

    private struct RulesReadFailure: Error {}

    @MainActor
    private final class ReadCounter {
        var reads = 0
    }

    @MainActor
    private final class Events {
        var events: [LocalFirstSyncDebugEvent] = []
        var queuedCount: Int { events.filter { $0.outcome == .queued }.count }
    }

    private func makeStore() async throws -> (LocalFirstActualStore, Events) {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let recorded = Events()
        let store = LocalFirstActualStore(
            keychain: bundle.keychain,
            fileManager: bundle.fileManager,
            syncDebugRecorder: { event in recorded.events.append(event) }
        )
        _ = try await store.openCachedBudget(bundle.budget)
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        return (store, recorded)
    }

    private var draft: TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_784_000_000),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "rules tail",
            cleared: false,
            isTransfer: false
        )
    }

    @Test func supersededRulesRefreshAfterCreateStillReportsCommitted() async throws {
        let (store, recorded) = try await makeStore()
        let queuedBefore = recorded.queuedCount
        let entered = TestLatch()
        let release = TestLatch()
        let counter = ReadCounter()
        store.rulesReadHook = { _ in
            counter.reads += 1
            guard counter.reads == 1 else { return }
            entered.trip()
            await release.wait()
        }
        defer { release.trip() }

        let create = Task { @MainActor in
            try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        }
        let parked = await entered.wait(timeout: .seconds(20)) { release.trip() }
        #expect(parked)
        try await store.refreshRules(budgetID: "group-1")
        let newerRules = try #require(store.cachedRules(budgetID: "group-1"))
        release.trip()

        let result = try await create.value

        #expect(result.ok)
        #expect(!result.refreshPending)
        #expect(recorded.queuedCount == queuedBefore + 1)
        #expect(store.cachedRules(budgetID: "group-1") == newerRules)
    }

    @Test func failedRulesReadAfterCreateReportsCommittedWithRefreshPending() async throws {
        let (store, recorded) = try await makeStore()
        let queuedBefore = recorded.queuedCount
        store.rulesReadHook = { _ in throw RulesReadFailure() }

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        #expect(result.ok)
        #expect(result.refreshPending)
        #expect(recorded.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }
}
