import Foundation
import GRDB
import Testing
@testable import Actualist

/// Concurrency 5.4 (audit CA-17): a read that outlives its session, or that a
/// write reload superseded, must not publish into the caches. The read
/// publication hook parks each read after its database fetch.
extension LocalFirstActualStoreTests {
    @MainActor
    private final class ReadGate {
        let entered = TestLatch()
        let release = TestLatch()
        var armed = true

        func install(on store: LocalFirstActualStore, site: ReadPublicationSite) {
            store.readPublicationHook = { [self] reached in
                guard reached == site, armed else { return }
                armed = false
                entered.trip()
                await release.wait()
            }
        }
    }

    /// Starts `read`, parks it after its fetch, runs `whileParked`, then releases it.
    private func parkedRead<T: Sendable>(
        _ site: ReadPublicationSite,
        on store: LocalFirstActualStore,
        read: @escaping @MainActor () async throws -> T,
        whileParked: () async throws -> Void
    ) async throws -> Result<T, any Error> {
        let gate = ReadGate()
        gate.install(on: store, site: site)
        let task = Task { try await read() }
        let parked = await gate.entered.wait(timeout: .seconds(20)) { gate.release.trip() }
        #expect(parked, "the read never reached its publication point")
        try await whileParked()
        gate.release.trip()
        return await task.result
    }

    private func reopenSameBudget(_ bundle: OpenedWritableStoreBundle) async throws {
        bundle.store.reset()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))
    }

    @Test func reportsDashboardReadFromAClosedSessionIsNotPublished() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let range = ReportDateRange.dashboard(through: Date())
        let result = try await parkedRead(.reportsDashboard, on: bundle.store, read: {
            try await bundle.store.refreshReportsDashboard(budgetID: "group-1", range: range)
        }, whileParked: { try await reopenSameBudget(bundle) })

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(bundle.store.cachedReportsDashboard(budgetID: "group-1", range: range) == nil)
    }

    @Test func availableMonthsReadFromAClosedSessionIsNotPublished() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        bundle.store.monthsByBudget["group-1"] = nil
        let result = try await parkedRead(.availableMonths, on: bundle.store, read: {
            try await bundle.store.availableMonths(budgetID: "group-1")
        }, whileParked: {
            try await reopenSameBudget(bundle)
            bundle.store.monthsByBudget["group-1"] = nil
        })

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(bundle.store.monthsByBudget["group-1"] == nil)
    }

    @Test func templateBrowserReadFromAClosedSessionIsNotPublished() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let result = try await parkedRead(.templateBrowser, on: bundle.store, read: {
            try await bundle.store.categoryTemplateBrowserSnapshot(budgetID: "group-1")
        }, whileParked: { try await reopenSameBudget(bundle) })

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(bundle.store.templateBrowserByBudget["group-1"] == nil)
    }

    @Test func olderCategoryFeedReadCannotOverwriteAWriteReload() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        try await store.refreshCategoryTransactions(budgetID: "group-1", categoryID: "groceries", month: "2026-07")
        let database = try #require(store.database)

        let result = try await parkedRead(.categoryFeed, on: store, read: {
            try await store.refreshCategoryTransactions(
                budgetID: "group-1", categoryID: "groceries", month: "2026-07"
            )
        }, whileParked: {
            _ = try await database.applyRemoteSyncMessages([ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:00:00.000Z-0000-peernode0000001",
                dataset: "transactions", row: "txn", column: "notes", serializedValue: "S:newer"
            )])
            try await store.reloadSelectedBudgetCache(budgetID: "group-1")
        })

        _ = try result.get()
        let cached = try #require(store.cachedCategoryTransactions(
            budgetID: "group-1", categoryID: "groceries", month: "2026-07"
        ))
        #expect(cached.transactions.first { $0.id == "txn" }?.notes == "newer")
    }

    @Test func olderUncategorizedFeedReadCannotOverwriteAWriteReload() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            INSERT INTO transactions (id, acct, date, amount, tombstone, notes)
            VALUES ('loose', 'checking', 20260704, -100, 0, 'old');
            """)
        let store = bundle.store
        _ = try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        let database = try #require(store.database)

        let result = try await parkedRead(.uncategorizedFeed, on: store, read: {
            try await store.uncategorizedTransactions(budgetID: "group-1", month: "2026-07")
        }, whileParked: {
            _ = try await database.applyRemoteSyncMessages([ActualSyncDecodedMessage(
                timestamp: "2026-07-04T12:00:00.000Z-0000-peernode0000001",
                dataset: "transactions", row: "loose", column: "notes", serializedValue: "S:newer"
            )])
            try await store.reloadSelectedBudgetCache(budgetID: "group-1")
        })

        _ = try result.get()
        let cached = try #require(store.cachedUncategorizedTransactions(budgetID: "group-1", month: "2026-07"))
        #expect(cached.transactions.first { $0.id == "loose" }?.notes == "newer")
    }

    @Test func launchWarmupDoesNotOverwriteANewerPendingCountWithAnOlderRead() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        store.syncStatus = LocalFirstSyncStatus(fileID: "group-1", groupID: "group-1")
        let database = try #require(store.database)

        let result: Result<Void, any Error> = try await parkedRead(.launchWarmupSyncStatus, on: store, read: {
            await store.warmLaunchCaches(budgetID: "group-1")
        }, whileParked: {
            var builder = LocalFirstSyncMessageBuilder()
            let draft = try builder.makeMessage(
                dataset: "accounts", row: "warm-write", column: "name", value: .string("Warm")
            )
            #expect(try await database.commitLocalSyncMessagesAndEnqueue([draft]) == 1)
            await store.recordSyncStatus(budgetID: "group-1", uploadedCount: nil, appliedCount: nil, error: nil)
        })

        try result.get()
        #expect(store.syncStatus(budgetID: "group-1")?.pendingLocalMessageCount == 1)
    }

    @Test func launchSeedIgnoresASnapshotWhoseRevisionAdvancedWhileItWasBeingRead() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let original = try #require(store.cachedBudgetMonth(budgetID: "group-1"))
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        store.reset()
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)

        let gate = ReadGate()
        gate.install(on: store, site: .launchSeed)
        let reopen = Task { try await store.openCachedBudget(bundle.budget) }
        let parked = await gate.entered.wait(timeout: .seconds(20)) { gate.release.trip() }
        #expect(parked)
        // A write advances the persistent revision while the snapshot is in hand.
        _ = try files.advanceRevision()
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE zero_budgets SET amount = 88888 WHERE month = 202607 AND category = 'groceries'"
            )
        }
        gate.release.trip()
        #expect(try await reopen.value)

        let seeded = try #require(store.cachedBudgetMonth(budgetID: "group-1"))
        #expect(seeded.month != original.month)
    }
}
