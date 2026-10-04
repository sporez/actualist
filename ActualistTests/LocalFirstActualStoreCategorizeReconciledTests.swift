import Foundation
import GRDB
import Testing
@testable import Actualist

/// Audit 2.14: categorize must honor the reconciled-transaction guard that
/// edit and delete already enforce, inside the same write transaction.
extension LocalFirstActualStoreTests {
    private static let reconciledCategorizeFixtureSQL = """
        ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
        UPDATE transactions SET reconciled = 1 WHERE id = 'txn';
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, is_parent, cleared, transferred_id, reconciled)
        VALUES ('xfer', 'checking', 20260705, -500, NULL, 0, 0, 1, 'xpair', 0),
               ('xpair', 'savings', 20260705, 500, NULL, 0, 0, 1, 'xfer', 1),
               ('plain', 'checking', 20260706, -700, NULL, 0, 0, 0, NULL, 0);
        """

    private func categoryAndOutboxCount(
        _ bundle: OpenedWritableStoreBundle,
        id: String
    ) async throws -> (category: String?, outbox: Int) {
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        return try await DatabaseQueue(path: url.path).read { db in
            (
                try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = ?", arguments: [id]),
                // The outbox table is created by the first local write.
                try db.tableExists("actualist_outbox")
                    ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? -1
                    : 0
            )
        }
    }

    @Test func categorizeRefusesAReconciledRowWithoutAuthorizationAndWritesNothing() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.reconciledCategorizeFixtureSQL
        )
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let before = try await categoryAndOutboxCount(bundle, id: "txn")

        do {
            _ = try await bundle.store.categorizeTransactionAndRefresh(
                transaction, categoryID: "utilities", budgetID: "group-1"
            ) {}
            Issue.record("categorize changed a reconciled row without confirmation")
        } catch ReconciledTransactionMutationError.confirmationRequired(let review) {
            #expect(review.targetReconciledTransactionIDs == ["txn"])
        }

        let after = try await categoryAndOutboxCount(bundle, id: "txn")
        #expect(after.category == before.category)
        #expect(after.outbox == before.outbox)
    }

    @Test func categorizeRefusesARowWhoseTransferCounterpartIsReconciled() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.reconciledCategorizeFixtureSQL
        )
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "xfer"))

        do {
            _ = try await bundle.store.categorizeTransactionAndRefresh(
                transaction, categoryID: "utilities", budgetID: "group-1"
            ) {}
            Issue.record("categorize changed a row whose transfer pair is reconciled")
        } catch ReconciledTransactionMutationError.confirmationRequired(let review) {
            #expect(review.targetReconciledTransactionIDs.isEmpty)
            #expect(review.pairedReconciledTransactionIDs == ["xpair"])
        }

        let after = try await categoryAndOutboxCount(bundle, id: "xfer")
        #expect(after.category == nil)
    }

    @Test func categorizeWritesAReconciledRowWithItsExactAuthorization() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.reconciledCategorizeFixtureSQL
        )
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let review = try #require(
            try await bundle.store.reconciledMutationReview(budgetID: "group-1", transactionID: "txn")
        )

        _ = try await bundle.store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "utilities",
            budgetID: "group-1",
            reconciliationAuthorizations: ["txn": review.authorization]
        ) {}

        let after = try await categoryAndOutboxCount(bundle, id: "txn")
        #expect(after.category == "utilities")
    }

    @Test func categorizeWritesATransferRowWithItsPairedAuthorization() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.reconciledCategorizeFixtureSQL
        )
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "xfer"))
        let review = try #require(
            try await bundle.store.reconciledMutationReview(budgetID: "group-1", transactionID: "xfer")
        )

        _ = try await bundle.store.categorizeTransactionAndRefresh(
            transaction,
            categoryID: "utilities",
            budgetID: "group-1",
            reconciliationAuthorizations: ["xfer": review.authorization]
        ) {}

        let after = try await categoryAndOutboxCount(bundle, id: "xfer")
        #expect(after.category == "utilities")
    }

    @Test func categorizeTransactionsFailsClosedForTheWholeBatchWhenOneRowIsReconciled() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.reconciledCategorizeFixtureSQL
        )
        let plain = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "plain"))
        let reconciled = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))

        await #expect(throws: ReconciledTransactionMutationError.self) {
            _ = try await bundle.store.categorizeTransactionsAndRefresh(
                [plain, reconciled], categoryID: "utilities", budgetID: "group-1"
            ) {}
        }

        let after = try await categoryAndOutboxCount(bundle, id: "plain")
        #expect(after.category == nil)
    }
}
