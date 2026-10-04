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
        store.userActionBeforeCommitHook = { [store] in
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

        let loaded = try await store.moveMoneyAndRefresh(
            expectedMode: nil,
            command: BudgetMoveMoneyCommand(
                fromCategoryID: "groceries", toCategoryID: "utilities", amount: 10_000
            ),
            budgetID: "group-1",
            month: "2026-07"
        ) {}

        let categories = Dictionary(
            uniqueKeysWithValues: loaded.month.categoryGroups.flatMap(\.categories).map { ($0.id, $0) }
        )
        #expect(categories["groceries"]?.budgeted == 60_000)
        #expect(categories["utilities"]?.budgeted == 10_000)
    }
}
