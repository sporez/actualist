import Foundation
import GRDB
import Testing
@testable import Actualist

/// Store-level CSV import against the transfer, split and off-budget rules
/// shared with Bank Sync (mistakes.md 2026-09-16).
@MainActor
struct TransactionCSVImportStoreRulesTests {
    private typealias Bundle = LocalFirstActualStoreTests.OpenedWritableStoreBundle

    /// `parent1` is a split parent in checking with two children, all
    /// uncleared. `leg1` is a transfer leg in checking.
    private static let fixtureSQL = TransactionCSVImportRevalidationTests.fixtureSQL + """
        UPDATE transactions SET cleared = 0, isChild = 0, description = NULL;
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, isChild)
            VALUES ('parent1', 'checking', 20260705, -2000, NULL, 0, NULL, 1, 0, 0);
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, isChild)
            VALUES ('parent1/c1', 'checking', 20260705, -1000, 'groceries', 0, 'parent1', 0, 0, 1);
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, isChild)
            VALUES ('parent1/c2', 'checking', 20260705, -1000, 'groceries', 0, 'parent1', 0, 0, 1);
        INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent, cleared, isChild, transferred_id, description)
            VALUES ('leg1', 'checking', 20260710, -5000, NULL, 0, NULL, 0, 0, 0, 'leg2', 'xfer-savings');
        """

    private func makeBundle() async throws -> Bundle {
        try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.fixtureSQL
        )
    }

    private func importCSV(
        _ body: String,
        into accountID: String,
        bundle: Bundle
    ) async throws -> (review: TransactionCSVImportReview, result: TransactionCSVImportApplyResult) {
        let review = try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: accountID,
                data: Data(("Date,Payee,Notes,Amount,Category,Cleared\n" + body + "\n").utf8),
                options: TransactionCSVImportOptions()
            )
        )
        let result = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: accountID,
                sessionGeneration: review.sessionGeneration,
                rows: review.rows.filter {
                    if case .insert = $0.disposition { return true }
                    if case .update = $0.disposition { return true }
                    return false
                }
            )
        )
        return (review, result)
    }

    private func read<T>(_ bundle: Bundle, _ body: (Database) throws -> T) async throws -> T {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read(body)
    }

    private func column(_ bundle: Bundle, _ name: String, id: String) async throws -> String? {
        try await read(bundle) {
            try String.fetchOne($0, sql: "SELECT \(name) FROM transactions WHERE id = ?", arguments: [id])
        }
    }

    @Test func splitParentKeepsNullCategoryAndClearedReachesChildren() async throws {
        let bundle = try await makeBundle()
        let (review, result) = try await importCSV(
            "2026-07-05,Coffee Shop,,-20.00,Groceries,Cleared",
            into: "checking",
            bundle: bundle
        )
        #expect(review.rows.count == 1)
        #expect(result.updatedCount == 1)
        #expect(result.insertedCount == 0)
        #expect(try await column(bundle, "category", id: "parent1") == nil)
        #expect(try await column(bundle, "cleared", id: "parent1") == "1")
        #expect(try await column(bundle, "cleared", id: "parent1/c1") == "1")
        #expect(try await column(bundle, "cleared", id: "parent1/c2") == "1")
        // Children keep their own categories.
        #expect(try await column(bundle, "category", id: "parent1/c1") == "groceries")
    }

    @Test func childRowIsNeverMatchedDirectly() async throws {
        let bundle = try await makeBundle()
        let review = try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: "checking",
                data: Data("Date,Payee,Amount\n2026-07-05,Nobody,-10.00\n".utf8),
                options: TransactionCSVImportOptions()
            )
        )
        #expect(review.rows.map(\.disposition) == [.insert(isTransfer: false)])
    }

    @Test func matchedTransferLegGetsNoCategory() async throws {
        let bundle = try await makeBundle()
        let (_, result) = try await importCSV(
            "2026-07-10,Coffee Shop,,-50.00,Groceries,",
            into: "checking",
            bundle: bundle
        )
        #expect(result.updatedCount == 1)
        #expect(try await column(bundle, "category", id: "leg1") == nil)
        #expect(try await column(bundle, "description", id: "leg1") == "xfer-savings")
    }

    @Test func transferPayeeIsNotWrittenOntoAMatchedNonTransferRow() async throws {
        let bundle = try await makeBundle()
        let (_, result) = try await importCSV(
            "2026-07-03,To Savings,,-123.45,,",
            into: "checking",
            bundle: bundle
        )
        #expect(result.updatedCount == 1)
        #expect(try await column(bundle, "description", id: "txn") == nil)
    }

    @Test func offBudgetInsertHasNoCategory() async throws {
        let bundle = try await makeBundle()
        let (review, result) = try await importCSV(
            "2026-07-12,Coffee Shop,,-8.00,Groceries,",
            into: "tracking",
            bundle: bundle
        )
        #expect(review.rows.map(\.disposition) == [.insert(isTransfer: false)])
        #expect(result.insertedCount == 1)
        let categories = try await read(bundle) {
            try Row.fetchAll($0, sql: "SELECT category FROM transactions WHERE acct = 'tracking'")
                .map { $0["category"] as String? }
        }
        #expect(categories == [nil])
    }

    @Test func onBudgetInsertKeepsItsCategory() async throws {
        let bundle = try await makeBundle()
        _ = try await importCSV(
            "2026-07-12,Coffee Shop,,-8.00,Groceries,",
            into: "checking",
            bundle: bundle
        )
        let categories = try await read(bundle) {
            try Row.fetchAll($0, sql: "SELECT category FROM transactions WHERE acct = 'checking' AND date = 20260712")
                .map { $0["category"] as String? }
        }
        #expect(categories == ["groceries"])
    }
}
