import Foundation
import GRDB
import Testing
@testable import Actualist

/// CSV import apply must revalidate its review against the live budget: the
/// session, and every matched row, at commit time. Any mismatch rejects the
/// whole import and writes nothing.
@MainActor
struct TransactionCSVImportRevalidationTests {
    private typealias Bundle = LocalFirstActualStoreTests.OpenedWritableStoreBundle

    static let fixtureSQL = """
        ALTER TABLE transactions ADD COLUMN imported_id TEXT;
        ALTER TABLE transactions ADD COLUMN imported_description TEXT;
        INSERT INTO payees VALUES ('to-savings', 'To Savings', 'savings', 0);
        INSERT INTO payee_mapping VALUES ('to-savings', 'to-savings');
        """

    private func makeBundle() async throws -> Bundle {
        try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: Self.fixtureSQL
        )
    }

    /// Matches the fixture row `txn` (-123.45 on 2026-07-03, no payee) and
    /// inserts one new row, so a stale match must also discard the insert.
    private let matchAndInsertCSV = Data("""
        Date,Payee,Notes,Amount
        2026-07-03,Coffee Shop,,-123.45
        2026-07-20,Brand New Payee,,-9.99

        """.utf8)

    private func review(_ bundle: Bundle, _ data: Data) async throws -> TransactionCSVImportReview {
        try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: "checking",
                data: data,
                options: TransactionCSVImportOptions()
            )
        )
    }

    private func applyRequest(
        _ review: TransactionCSVImportReview,
        generation: Int? = nil
    ) -> TransactionCSVImportApplyRequest {
        TransactionCSVImportApplyRequest(
            budgetID: "group-1",
            accountID: "checking",
            sessionGeneration: generation ?? review.sessionGeneration,
            rows: review.rows.filter { $0.outcome.writes }
        )
    }

    private func mutate(_ bundle: Bundle, _ sql: String) throws {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        try DatabaseQueue(path: url.path).write { db in try db.execute(sql: sql) }
    }

    private func pendingCount(_ bundle: Bundle) async throws -> Int {
        let database = try #require(bundle.store.database)
        return try await database.pendingLocalSyncMessageCount()
    }

    private func transactionCount(_ bundle: Bundle) async throws -> Int {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") ?? 0
        }
    }

    private func expectRejected(_ bundle: Bundle, _ request: TransactionCSVImportApplyRequest) async throws {
        let pendingBefore = try await pendingCount(bundle)
        let countBefore = try await transactionCount(bundle)
        await #expect(throws: TransactionCSVImportError.matchChanged(line: 1)) {
            _ = try await bundle.store.applyTransactionCSVImport(request)
        }
        #expect(try await pendingCount(bundle) == pendingBefore)
        #expect(try await transactionCount(bundle) == countBefore)
    }

    @Test func reviewCarriesTheSessionItWasMatchedAgainst() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        #expect(reviewed.sessionGeneration == bundle.store.budgetSessionGeneration)
        #expect(reviewed.rows.count == 2)
        #expect(reviewed.rows[0].outcome.kind == .update, "expected the first row to match txn")
    }

    @Test func staleSessionGenerationThrowsAndWritesNothing() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        let pendingBefore = try await pendingCount(bundle)
        let countBefore = try await transactionCount(bundle)
        await #expect(throws: CancellationError.self) {
            _ = try await bundle.store.applyTransactionCSVImport(
                applyRequest(reviewed, generation: reviewed.sessionGeneration - 1)
            )
        }
        #expect(try await pendingCount(bundle) == pendingBefore)
        #expect(try await transactionCount(bundle) == countBefore)
    }

    @Test func applyAfterStoreResetThrows() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        let database = try #require(bundle.store.database)
        bundle.store.reset()
        await #expect(throws: (any Error).self) {
            _ = try await bundle.store.applyTransactionCSVImport(applyRequest(reviewed))
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func matchTombstonedAfterReviewRejectsTheWholeImport() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        try mutate(bundle, "UPDATE transactions SET tombstone = 1 WHERE id = 'txn'")
        try await expectRejected(bundle, applyRequest(reviewed))
    }

    @Test func matchMovedToAnotherAccountRejects() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        try mutate(bundle, "UPDATE transactions SET acct = 'savings' WHERE id = 'txn'")
        try await expectRejected(bundle, applyRequest(reviewed))
    }

    @Test func matchReconciledAfterReviewRejectsWithTheTypedError() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        try mutate(bundle, "UPDATE transactions SET reconciled = 1 WHERE id = 'txn'")
        try await expectRejected(bundle, applyRequest(reviewed))
    }

    @Test func payeeFilledBySyncAfterReviewRejects() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        try mutate(bundle, "UPDATE transactions SET description = 'coffee' WHERE id = 'txn'")
        try await expectRejected(bundle, applyRequest(reviewed))
    }

    /// Strict id checking (sync.ts ~890) only fuzzy-matches a row with no
    /// `imported_id` when the file row has one, so an id synced onto the match
    /// after review means a fresh review would insert instead. The stale review
    /// must not write its id over the synced one.
    @Test func importedIDSetBySyncAfterReviewRejects() async throws {
        let bundle = try await makeBundle()
        let csv = Data("Date,Payee,Notes,Amount,imported_id\n2026-07-03,Coffee Shop,,-123.45,csv-1\n".utf8)
        let reviewed = try await review(bundle, csv)
        #expect(reviewed.rows.map(\.outcome.kind) == [.update])
        try mutate(bundle, "UPDATE transactions SET imported_id = 'bank-9' WHERE id = 'txn'")
        #expect(try await review(bundle, csv).rows.map(\.outcome.kind) == [.insert])

        try await expectRejected(bundle, applyRequest(reviewed))
        #expect(try await storedImportedID(bundle) == "bank-9")
    }

    /// An exact-id match whose id changed after review would not match on a
    /// fresh review either, so its payee fill must not land on the row.
    @Test func exactIDMatchChangedAfterReviewRejects() async throws {
        let bundle = try await makeBundle()
        try mutate(bundle, "UPDATE transactions SET imported_id = 'csv-1' WHERE id = 'txn'")
        let csv = Data("Date,Payee,Notes,Amount,imported_id\n2026-07-03,Coffee Shop,,-123.45,csv-1\n".utf8)
        let reviewed = try await review(bundle, csv)
        #expect(reviewed.rows.map(\.outcome.kind) == [.update])
        try mutate(bundle, "UPDATE transactions SET imported_id = 'bank-9' WHERE id = 'txn'")

        try await expectRejected(bundle, applyRequest(reviewed))
        #expect(try await storedImportedID(bundle) == "bank-9")
    }

    private func storedImportedID(_ bundle: Bundle) async throws -> String? {
        let url = try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
        return try await DatabaseQueue(path: url.path).read {
            try String.fetchOne($0, sql: "SELECT imported_id FROM transactions WHERE id = 'txn'")
        }
    }

    @Test func untouchedMatchStillAppliesAfterRevalidation() async throws {
        let bundle = try await makeBundle()
        let reviewed = try await review(bundle, matchAndInsertCSV)
        let result = try await bundle.store.applyTransactionCSVImport(applyRequest(reviewed))
        #expect(result.updatedCount == 1)
        #expect(result.insertedCount == 1)
    }
}
