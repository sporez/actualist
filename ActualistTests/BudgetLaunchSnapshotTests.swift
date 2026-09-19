import Foundation
import GRDB
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func budgetLaunchSnapshotRoundTripsVisibleFirstFrame() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let pair = try files.readRevisionAndSnapshot()
        let snapshot = try #require(pair.snapshot)
        let live = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let mode = try #require(live.modeIdentity)

        let data = try JSONEncoder.actual.encode(snapshot)
        let decoded = try JSONDecoder.actual.decode(BudgetLaunchSnapshot.self, from: data)
        let restored = try #require(decoded.restoredMonth(
            revision: pair.revision,
            localFileID: "file-1",
            budgetID: "group-1",
            groupID: "group-1",
            preferredCalendarMonth: YearMonth(date: Date()).rawValue,
            modeIdentity: mode
        ))

        #expect(decoded == snapshot)
        #expect(restored == live)
        try expectBudgetArtifactIsHardened(files.revisionURL)
        try expectBudgetArtifactIsHardened(files.snapshotURL)
    }

    @Test func validBudgetLaunchSnapshotSeedsReopenWithoutLiveProjection() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let original = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        bundle.store.reset()
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE zero_budgets SET amount = 77777 WHERE month = 202607 AND category = 'groceries'"
            )
        }

        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        let restored = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))

        // The direct fixture edit deliberately bypasses the production mutation
        // boundary. Equality proves reopen consumed the materialized projection
        // instead of recalculating the changed SQLite month.
        #expect(restored == original)
    }

    @Test func revisionMismatchAndBumpBeforeWriteCrashRejectOldSnapshot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let original = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let before = try files.prepareRevision()
        bundle.store.reset()

        // Simulates termination after the persistent bump but before a
        // replacement snapshot can be generated.
        let advanced = try files.advanceRevision()
        #expect(advanced == before + 1)
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE zero_budgets SET amount = 88888 WHERE month = 202607 AND category = 'groceries'"
            )
        }

        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        let liveFallback = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        #expect(liveFallback.month != original.month)
        let replacement = try files.readRevisionAndSnapshot()
        #expect(replacement.revision == advanced)
        #expect(replacement.snapshot?.revision == advanced)
        #expect(replacement.snapshot?.month == liveFallback.month)
    }

    @Test func olderProjectionCannotWinSnapshotWriteRace() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let loaded = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let revision = try files.prepareRevision()
        let stale = try #require(BudgetLaunchSnapshot(
            revision: revision,
            localFileID: "file-1",
            budgetID: "group-1",
            groupID: "group-1",
            preferredCalendarMonth: YearMonth(date: Date()).rawValue,
            loaded: loaded
        ))

        let advanced = try files.advanceRevision()
        #expect(advanced == revision + 1)
        #expect(try files.writeSnapshot(stale, ifRevisionIs: revision) == false)
        let pair = try files.readRevisionAndSnapshot()
        #expect(pair.revision == advanced)
        #expect(pair.snapshot?.restoredMonth(
            revision: advanced,
            localFileID: "file-1",
            budgetID: "group-1",
            groupID: "group-1",
            preferredCalendarMonth: YearMonth(date: Date()).rawValue,
            modeIdentity: try #require(loaded.modeIdentity)
        ) == nil)
    }

    @Test func corruptBudgetLaunchSnapshotIsHarmlessCacheMiss() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let original = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        bundle.store.reset()
        try Data("{truncated".utf8).write(to: files.snapshotURL, options: .atomic)
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE zero_budgets SET amount = 99999 WHERE month = 202607 AND category = 'groceries'"
            )
        }

        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1")?.month != original.month)
    }

    @Test(arguments: ["schemaVersion", "projectionVersion"])
    func unsupportedBudgetLaunchSnapshotVersionFallsBack(_ key: String) async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let original = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let snapshotData = try Data(contentsOf: files.snapshotURL)
        var object = try #require(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        object[key] = 999
        bundle.store.reset()
        try JSONSerialization.data(withJSONObject: object).write(to: files.snapshotURL, options: .atomic)
        let queue = try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE zero_budgets SET amount = 45678 WHERE month = 202607 AND category = 'groceries'"
            )
        }

        #expect(try await bundle.store.openCachedBudget(bundle.budget))
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1")?.month != original.month)
    }

    @Test func budgetAndMonthIdentityRejectOtherwiseDecodableSnapshot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let pair = try files.readRevisionAndSnapshot()
        let snapshot = try #require(pair.snapshot)
        let loaded = try #require(bundle.store.cachedBudgetMonth(budgetID: "group-1"))
        let mode = try #require(loaded.modeIdentity)

        #expect(snapshot.restoredMonth(
            revision: pair.revision,
            localFileID: "file-1",
            budgetID: "group-2",
            groupID: "group-2",
            preferredCalendarMonth: snapshot.preferredCalendarMonth,
            modeIdentity: mode
        ) == nil)
        #expect(snapshot.restoredMonth(
            revision: pair.revision,
            localFileID: "file-1",
            budgetID: "group-1",
            groupID: "group-1",
            preferredCalendarMonth: "2099-01",
            modeIdentity: mode
        ) == nil)
    }

    @Test func eraseLocalDataRemovesLaunchRevisionAndSnapshot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        #expect(FileManager.default.fileExists(atPath: files.revisionURL.path))
        #expect(FileManager.default.fileExists(atPath: files.snapshotURL.path))

        try bundle.store.eraseLocalData()

        #expect(!FileManager.default.fileExists(atPath: files.revisionURL.path))
        #expect(!FileManager.default.fileExists(atPath: files.snapshotURL.path))
    }

    @Test func representativeLocalWritesAdvancePersistentLaunchRevision() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let initial = try files.prepareRevision()

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            expectedMode: nil,
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let afterAssignment = try files.prepareRevision()
        #expect(afterAssignment > initial)

        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 12),
            amountMinorUnits: -2_000,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        _ = try await bundle.store.createTransactionAndRefresh(draft, budgetID: "group-1") {}
        #expect(try files.prepareRevision() > afterAssignment)
    }

    @Test func changedRemoteSyncAdvancesRevisionButDuplicateDoesNot() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let files = try bundle.fileManager.launchSnapshotFiles(fileID: "file-1")
        let database = try #require(bundle.store.database)
        let message = remoteMessage(index: 700, row: "txn", column: "amount", value: .int(-54_321))
        let before = try files.prepareRevision()

        #expect(try await database.applyRemoteSyncMessages([message]) == 1)
        let afterChange = try files.prepareRevision()
        #expect(afterChange > before)
        #expect(try files.readRevisionAndSnapshot().snapshot?.revision != afterChange)
        #expect(try await database.applyRemoteSyncMessages([message]) == 0)
        #expect(try files.prepareRevision() == afterChange)
    }

    @Test func launchSnapshotNeverBypassesEncryptedBudgetRequirement() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: "file-1",
            cloudFileID: "file-1",
            groupID: "group-1",
            budgetName: "Encrypted Budget",
            encryptionKeyID: "missing-key",
            nodeID: "node1"
        )
        try JSONEncoder.actual.encode(metadata).write(
            to: bundle.fileManager.metadataURL(fileID: "file-1"),
            options: .atomic
        )
        bundle.store.reset()

        await #expect(throws: LocalFirstError.encryptedBudgetRequiresPassword) {
            _ = try await bundle.store.openCachedBudget(bundle.budget)
        }
        #expect(bundle.store.cachedBudgetMonth(budgetID: "group-1") == nil)
    }
}
