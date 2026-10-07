import Foundation
import Testing
@testable import Actualist

/// Concurrency 5.2a/5.2b (audit CA-12): payee gestures decide from the rows of
/// the write transaction, not from a read taken before a remote change landed.
/// `userActionBeforeCommitHook` lands that change between the read and the commit.
extension LocalFirstActualStoreTests {
    private static let payeeRemoteTimestamp = "2026-01-01T00:00:00.000Z-0000-0000000000000002"

    private func payeeRemote(
        _ dataset: String, _ row: String, _ column: String, _ value: String
    ) -> ActualSyncDecodedMessage {
        ActualSyncDecodedMessage(
            timestamp: Self.payeeRemoteTimestamp, dataset: dataset, row: row, column: column, serializedValue: value
        )
    }

    private func landPayeeRemote(_ messages: [ActualSyncDecodedMessage], on store: LocalFirstActualStore) {
        store.userActionBeforeCommitHook = { [store] in
            store.userActionBeforeCommitHook = nil
            do {
                _ = try await store.requireDatabase(for: "group-1").applyRemoteSyncMessages(messages)
            } catch {
                Issue.record("could not land the remote change: \(error)")
            }
        }
    }

    @Test func deleteRefusesAPayeeAnotherDeviceStartedUsingBeforeCommit() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO payees VALUES ('late-use', 'Late Use', NULL, 0);
            INSERT INTO payee_mapping VALUES ('late-use', 'late-use');
            """)
        landPayeeRemote([payeeRemote("transactions", "txn", "description", "S:late-use")], on: store)

        await #expect(throws: LocalFirstError.self) {
            try await store.deletePayeeAndRefresh(budgetID: "group-1", payeeID: "late-use")
        }

        let database = try #require(store.database)
        let live = try await database.fetchPayeeManagementSnapshot().payees
        #expect(live.contains { $0.id == "late-use" })
    }

    @Test func mergeRetargetsAMappingRowThatLandedBeforeCommit() async throws {
        let store = try await makeOpenedWritableStore(additionalFixtureSQL: """
            INSERT INTO payees VALUES ('cafe-a', 'Cafe A', NULL, 0);
            INSERT INTO payees VALUES ('cafe-b', 'Cafe B', NULL, 0);
            INSERT INTO payee_mapping VALUES ('cafe-a', 'cafe-a');
            INSERT INTO payee_mapping VALUES ('cafe-b', 'cafe-b');
            """)
        // Another device merged Cafe C into Cafe A after this merge was reviewed.
        landPayeeRemote([payeeRemote("payee_mapping", "cafe-c", "targetId", "S:cafe-a")], on: store)

        try await store.mergePayeesAndRefresh(
            budgetID: "group-1", sourcePayeeIDs: ["cafe-a"], targetPayeeID: "cafe-b"
        )

        let database = try #require(store.database)
        let pending = try await database.pendingLocalSyncMessages().map(\.message)
        #expect(pending.contains {
            $0.dataset == "payee_mapping" && $0.row == "cafe-c"
                && $0.column == "targetId" && $0.serializedValue == "S:cafe-b"
        })
    }
}
