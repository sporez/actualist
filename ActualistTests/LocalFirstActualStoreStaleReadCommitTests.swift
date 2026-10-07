import Foundation
import GRDB
import Testing
@testable import Actualist

/// Audit 2.13: a gesture must build its CRDT messages from the rows of the
/// write transaction, not from a read taken before a remote change landed.
/// `userActionBeforeCommitHook` lands that remote change between the old
/// pre-read and the commit.
extension LocalFirstActualStoreTests {
    private static let remoteTimestamp = "2026-01-01T00:00:00.000Z-0000-0000000000000001"

    private func remoteMessage(
        _ dataset: String, _ row: String, _ column: String, _ value: String
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: Self.remoteTimestamp, dataset: dataset, row: row, column: column, serializedValue: value
        )
    }

    private func landRemote(
        _ messages: [ActualSyncDecodedMessage],
        on store: LocalFirstActualStore
    ) {
        store.seams.userActionBeforeCommitHook = { [store] in
            do {
                _ = try await store.requireDatabase(for: "group-1").applyRemoteSyncMessages(messages)
            } catch {
                Issue.record("could not land the remote change: \(error)")
            }
        }
    }

    @Test func moveMoneyBuildsFromTheBudgetAfterARemoteAssign() async throws {
        let store = try await makeOpenedWritableStore()
        landRemote([remoteMessage("zero_budgets", "202607-groceries", "amount", "N:70000")], on: store)

        let loaded = try #require(await store.moveMoneyAndRefresh(
            expectedMode: nil,
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries", toCategoryID: "utilities", amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {})

        let categories = Dictionary(
            uniqueKeysWithValues: loaded.month.categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
        )
        #expect(categories["groceries"]?.budgeted == 60_000)
        #expect(categories["utilities"]?.budgeted == 10_000)
    }

    @Test func categorizeRejectsARowThatBecameASplitParentBeforeCommit() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let store = bundle.store
        let transaction = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
        landRemote([remoteMessage("transactions", "txn", "is_parent", "N:1")], on: store)

        await #expect(throws: LocalFirstError.unsupportedSplitWrite) {
            _ = try await store.categorizeTransactionAndRefresh(
                transaction, categoryID: "utilities", budgetID: "group-1"
            ) {}
        }

        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let category = try await DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn'")
        }
        #expect(category == "groceries")
    }

    @Test func deleteTombstonesAChildThatLandedRemotelyBeforeCommit() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: """
            ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
            \(TransactionBatchDeleteTests.family(children: 2))
            """)
        let parent = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "p"))
        landRemote([
            remoteMessage("transactions", "c3", "acct", "S:checking"),
            remoteMessage("transactions", "c3", "date", "N:20260705"),
            remoteMessage("transactions", "c3", "amount", "N:-300"),
            remoteMessage("transactions", "c3", "parent_id", "S:p"),
            remoteMessage("transactions", "c3", "isChild", "N:1"),
            remoteMessage("transactions", "c3", "tombstone", "N:0"),
        ], on: bundle.store)

        _ = try await bundle.store.deleteTransactionAndRefresh(parent, budgetID: "group-1") {}

        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let live = try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM transactions WHERE id IN ('p','c1','c2','c3') AND COALESCE(tombstone, 0) = 0"
            ) ?? -1
        }
        #expect(live == 0)
    }

    @Test func updateReportsTheAccountTheRowHasWhenTheWriteRuns() async throws {
        let store = try await makeOpenedWritableStore()
        landRemote([remoteMessage("transactions", "txn", "acct", "S:savings")], on: store)
        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: -12_345,
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            categoryID: "groceries",
            notes: "edited",
            cleared: false,
            isTransfer: false
        )

        let result = try await store.updateTransactionAndRefresh(
            "txn", with: draft, budgetID: "group-1",
            originalAccountID: "checking", originalMonth: "2026-07"
        ) {}

        #expect(Set(result.changed.accounts) == ["checking", "savings"])
    }

    @Test func templateApplyBuildsFromTheBudgetAfterARemotePreviousMonthEdit() async throws {
        let store = try await makeOpenedWritableStore()
        landRemote([
            remoteMessage("zero_budgets", "202606-copycat", "month", "N:202606"),
            remoteMessage("zero_budgets", "202606-copycat", "category", "S:copycat"),
            remoteMessage("zero_budgets", "202606-copycat", "amount", "N:4000"),
        ], on: store)

        let loaded = try await store.applyBudgetTemplateAndRefresh(
            expectedMode: nil, command: .category("copycat"), budgetID: "group-1", month: "2026-07"
        ) {}

        let copycat = try #require(loaded.month.categoryGroups.flatMap(\.categories).first { $0.id == "copycat" })
        #expect(copycat.budgeted == 4_000)
    }
}
