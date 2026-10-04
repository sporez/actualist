import Foundation
import Testing
@testable import Actualist

@MainActor
struct LocalFirstActualStoreCommitTailTests {
    private let support = LocalFirstActualStoreTests()

    private struct ReloadFailure: Error {}

    @MainActor
    private final class Fixture {
        var failFeedReads = false
        var events: [LocalFirstSyncDebugEvent] = []
        var queuedCount: Int { events.filter { $0.outcome == .queued }.count }
    }

    private func makeStore() async throws -> (LocalFirstActualStore, Fixture) {
        let bundle = try await support.makeOpenedWritableStoreBundle()
        let fixture = Fixture()
        let store = LocalFirstActualStore(
            keychain: bundle.keychain,
            fileManager: bundle.fileManager,
            syncDebugRecorder: { event in fixture.events.append(event) },
            transactionFeedPageReadHook: { _, _, _, _ in
                if fixture.failFeedReads { throw ReloadFailure() }
            }
        )
        _ = try await store.openCachedBudget(bundle.budget)
        try await store.refreshAccountTransactions(budgetID: "group-1", accountID: "checking")
        return (store, fixture)
    }

    private var draft: TransactionDraft {
        TransactionDraft(
            accountID: "checking",
            date: Date(timeIntervalSince1970: 1_784_000_000),
            amountMinorUnits: -725,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "tail",
            cleared: false,
            isTransfer: false
        )
    }

    @Test func failedReloadAfterCommitStillSchedulesFlushAndSucceeds() async throws {
        let (store, fixture) = try await makeStore()
        fixture.failFeedReads = true
        let queuedBefore = fixture.queuedCount

        let result = try await store.createTransactionAndRefresh(draft, budgetID: "group-1") {}

        #expect(result.ok)
        #expect(fixture.queuedCount == queuedBefore + 1)
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: "group-1") > 0)
    }

    @Test func tailReportsRefreshPendingOnlyWhenReloadFails() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")

        let ok = try await store.finishCommittedWrite(database: database, budgetID: "group-1") {}
        #expect(!ok)
        #expect(fixture.queuedCount == 1)

        let pending = try await store.finishCommittedWrite(database: database, budgetID: "group-1") {
            throw ReloadFailure()
        }
        #expect(pending)
        #expect(fixture.queuedCount == 2)
    }

    @Test func tailFlushesThenPropagatesCancellation() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")

        await #expect(throws: CancellationError.self) {
            try await store.finishCommittedWrite(database: database, budgetID: "group-1") {
                throw CancellationError()
            }
        }
        #expect(fixture.queuedCount == 1)
    }

    @Test func durableTailReportsPendingAndSessionAfterFailureAndRetirement() async throws {
        let (store, fixture) = try await makeStore()
        let database = try store.requireDatabase(for: "group-1")
        let generation = store.budgetSessionGeneration
        let requireSession: @MainActor () throws -> Void = { [store] in
            try store.requireSyncSession(database: database, budgetID: "group-1", generation: generation)
        }

        let failed: DurableCommitTailOutcome<Void> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: { throw ReloadFailure() }
        )
        #expect(failed.refreshPending)
        #expect(failed.sessionCurrent)
        #expect(fixture.queuedCount == 1)

        let clean: DurableCommitTailOutcome<Int> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: { 7 }
        )
        #expect(!clean.refreshPending)
        #expect(clean.value == 7)
        #expect(fixture.queuedCount == 2)

        store.closeOpenBudget()
        let retired: DurableCommitTailOutcome<Void> = await store.finishDurableCommit(
            database: database,
            budgetID: "group-1",
            requireSession: requireSession,
            reload: {}
        )
        #expect(retired.refreshPending)
        #expect(!retired.sessionCurrent)
    }
}
