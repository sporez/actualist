import Foundation
import GRDB
import Testing
@testable import Actualist

/// One `imported_id` rule for every importer (main-to-dev D6, audit F-9):
/// ids compare exactly, as upstream's `imported_id = ?` does (sync.ts ~850);
/// only surrounding whitespace is trimmed. `A1` and `a1` are different ids.
///
/// Wallet ids are lowercase at the source (`WalletTransactionMapper` lowercases
/// the FinanceKit UUID, asserted by `WalletTransactionMappingTests`), so exact
/// comparison keeps Wallet's duplicate detection.
@MainActor
struct ImportedIDExactnessTests {
    private let support = LocalFirstActualStoreTests()

    @Test func theNormalizerTrimsAndNeverFoldsCase() {
        #expect(BudgetDatabase.normalizedImportedID("A1") == "A1")
        #expect(BudgetDatabase.normalizedImportedID("a1") == "a1")
        #expect(BudgetDatabase.normalizedImportedID("  A1 ") == "A1")
        #expect(BudgetDatabase.normalizedImportedID("   ") == nil)
        #expect(BudgetDatabase.ImportedIDAbsence(accountID: "checking", importedIDs: ["A1", "a1"]).importedIDs == ["A1", "a1"])
    }

    @Test func storedIDsAreReadExactly() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: TransactionCSVImportRevalidationTests.fixtureSQL
        )
        try exec(bundle, """
            INSERT INTO transactions (id, acct, date, amount, imported_id, tombstone)
            VALUES ('stored', 'checking', 20260912, -999, 'A1', 0)
            """)
        let database = try #require(bundle.store.database)
        #expect(try await database.existingImportedIDs(accountID: "checking") == ["A1"])
    }

    @Test func aCSVRowWhoseIDDiffersOnlyByCaseImportsWithoutAConflict() async throws {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: TransactionCSVImportRevalidationTests.fixtureSQL
        )
        try exec(bundle, """
            INSERT INTO transactions (id, acct, date, amount, imported_id, tombstone)
            VALUES ('stored', 'checking', 20260912, -999, 'a1', 0)
            """)
        let review = try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1",
                accountID: "checking",
                data: Data("Date,Payee,Amount,imported_id\n2026-09-12,Landlord,-9.99,A1\n".utf8),
                options: TransactionCSVImportOptions()
            )
        )
        #expect(review.rows.map(\.outcome.kind) == [.insert])

        let result = try await bundle.store.applyTransactionCSVImport(
            TransactionCSVImportApplyRequest(
                budgetID: "group-1",
                accountID: "checking",
                sessionGeneration: review.sessionGeneration,
                rows: review.rows
            )
        )

        #expect(result.insertedCount == 1)
        #expect(try ids(bundle, column: "imported_id") == ["A1", "a1"])
    }

    @Test func aBankSyncRowWhoseIDDiffersOnlyByCaseAppliesWithoutAConflict() async throws {
        let remote = support.remoteAccount(balance: "0.00")
        let transport = LocalFirstActualStoreTests.StubSimpleFINTransport(
            remoteAccounts: [remote],
            response: SimpleFINTransactionsResponse(
                downloads: [remote.accountID: SimpleFINAccountDownload(
                    transactions: [support.remoteTransaction(
                        id: "A1", amount: "-10.00", dayID: "20260302", payeeName: "Coffee Shop"
                    )],
                    startingBalance: nil, errorType: nil, errorCode: nil
                )],
                errorType: nil, errorCode: nil
            )
        )
        // The stored row has another amount, so the download inserts instead of matching.
        let bundle = try await support.makeBankSyncStore(transport: transport, additionalFixtureSQL: """
            INSERT INTO transactions
                (id, acct, date, amount, category, tombstone, description, notes, cleared, is_parent)
            VALUES ('stored', 'savings', 20260302, -5000, NULL, 0, NULL, NULL, 0, 0);
            """)
        try exec(bundle, "UPDATE transactions SET financial_id = 'a1' WHERE id = 'stored'")
        try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")

        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(plan.inserts.compactMap(\.financialID) == ["A1"])
        let result = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")

        #expect(result.insertedCount == 1)
        #expect(try ids(bundle, column: "financial_id") == ["A1", "a1"])
    }

    // MARK: - Helpers

    private func databaseURL(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> URL {
        try bundle.fileManager.databaseURL(fileID: #require(bundle.budget.budgetID))
    }

    private func exec(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle, _ sql: String) throws {
        let url = try databaseURL(bundle)
        try DatabaseQueue(path: url.path).write { db in try db.execute(sql: sql) }
    }

    private func ids(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle, column: String) throws -> [String] {
        let queue = try DatabaseQueue(path: databaseURL(bundle).path)
        return try queue.readSync {
            try String.fetchAll($0, sql: "SELECT \(column) FROM transactions WHERE \(column) IS NOT NULL ORDER BY \(column)")
        }
    }
}
