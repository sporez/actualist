import Foundation
import GRDB
import Testing
@testable import Actualist

/// The short call shapes of the transaction gestures (no `actionSource`) record
/// a UI action, an explicit source is recorded as given, and a reconciliation
/// authorization handed to the repository protocol reaches the store.
extension LocalFirstActualStoreTests {
    private static let reconciledFixtureSQL = """
        ALTER TABLE transactions ADD COLUMN reconciled INTEGER;
        UPDATE transactions SET reconciled = 1 WHERE id = 'txn';
        """

    private func edited(_ baseline: ActualTransaction, amount: Int) throws -> TransactionDraft {
        var draft = TransactionDraft(
            accountID: baseline.account,
            date: try makeDate(year: 2026, month: 7, day: 3),
            amountMinorUnits: amount,
            payeeID: baseline.payee,
            payeeName: "",
            categoryID: baseline.category,
            notes: baseline.notes,
            cleared: baseline.cleared?.boolValue ?? false,
            isTransfer: false
        )
        draft.reconciled = baseline.reconciled
        return draft
    }

    private func loggedSource(_ store: LocalFirstActualStore) async throws -> BudgetActionSource? {
        let rows = try await store.recentBudgetActions(budgetID: "group-1")
        return rows.count == 1 ? rows[0].source : nil
    }

    private func amount(_ bundle: OpenedWritableStoreBundle) async throws -> Int? {
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        return try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT amount FROM transactions WHERE id = 'txn'")
        }
    }

    @Test func updateRecordsTheCallersActionSource() async throws {
        for source in [nil, BudgetActionSource.shortcuts] {
            let store = try await makeOpenedWritableStore()
            let baseline = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
            let draft = try edited(baseline, amount: -20_000)
            if let source {
                _ = try await store.updateTransactionAndRefresh(
                    "txn", with: draft, budgetID: "group-1", originalAccountID: "checking",
                    originalMonth: "2026-07", actionSource: source, didUpdate: {}
                )
            } else {
                _ = try await store.updateTransactionAndRefresh(
                    "txn", with: draft, budgetID: "group-1", originalAccountID: "checking",
                    originalMonth: "2026-07", didUpdate: {}
                )
            }
            #expect(try await loggedSource(store) == (source ?? .ui))
        }
    }

    @Test func deleteRecordsTheCallersActionSource() async throws {
        for source in [nil, BudgetActionSource.shortcuts] {
            let store = try await makeOpenedWritableStore()
            let transaction = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
            if let source {
                _ = try await store.deleteTransactionAndRefresh(
                    transaction, budgetID: "group-1", actionSource: source, didDelete: {}
                )
            } else {
                _ = try await store.deleteTransactionAndRefresh(transaction, budgetID: "group-1", didDelete: {})
            }
            #expect(try await loggedSource(store) == (source ?? .ui))
        }
    }

    @Test func categorizeRecordsTheCallersActionSource() async throws {
        for source in [nil, BudgetActionSource.shortcuts] {
            let store = try await makeOpenedWritableStore()
            let transaction = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
            if let source {
                _ = try await store.categorizeTransactionAndRefresh(
                    transaction, categoryID: "utilities", budgetID: "group-1",
                    actionSource: source, didUpdate: {}
                )
            } else {
                _ = try await store.categorizeTransactionAndRefresh(
                    transaction, categoryID: "utilities", budgetID: "group-1", didUpdate: {}
                )
            }
            #expect(try await loggedSource(store) == (source ?? .ui))
        }
    }

    @Test func categorizeTransactionsRecordsTheCallersActionSource() async throws {
        for source in [nil, BudgetActionSource.shortcuts] {
            let store = try await makeOpenedWritableStore()
            let transaction = try #require(try await store.fetchTransaction(budgetID: "group-1", id: "txn"))
            if let source {
                _ = try await store.categorizeTransactionsAndRefresh(
                    [transaction], categoryID: "utilities", budgetID: "group-1",
                    actionSource: source, didUpdate: {}
                )
            } else {
                _ = try await store.categorizeTransactionsAndRefresh(
                    [transaction], categoryID: "utilities", budgetID: "group-1", didUpdate: {}
                )
            }
            #expect(try await loggedSource(store) == (source ?? .ui))
        }
    }

    @Test func moveMoneyRecordsTheCallersActionSource() async throws {
        let command = BudgetMoveMoneyCommand(fromCategoryID: "groceries", toCategoryID: "dining", amount: 500)
        for source in [nil, BudgetActionSource.shortcuts] {
            for single in [true, false] {
                let store = try await makeOpenedWritableStore()
                if let source {
                    if single {
                        _ = try await store.moveMoneyAndRefresh(
                            expectedMode: nil, command: command, budgetID: "group-1", month: "2026-07",
                            actionSource: source, didMove: {}
                        )
                    } else {
                        _ = try await store.moveMoneyAndRefresh(
                            expectedMode: nil, commands: [command], budgetID: "group-1", month: "2026-07",
                            actionSource: source, didMove: {}
                        )
                    }
                } else if single {
                    _ = try await store.moveMoneyAndRefresh(
                        expectedMode: nil, command: command, budgetID: "group-1", month: "2026-07", didMove: {}
                    )
                } else {
                    _ = try await store.moveMoneyAndRefresh(
                        expectedMode: nil, commands: [command], budgetID: "group-1", month: "2026-07", didMove: {}
                    )
                }
                #expect(try await loggedSource(store) == (source ?? .ui))
            }
        }
    }

    @Test func protocolUpdateCarriesTheReconciliationAuthorizationToTheStore() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.reconciledFixtureSQL)
        let repository: any TransactionRepositoryProtocol = bundle.store
        let baseline = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let review = try #require(
            try await bundle.store.reconciledMutationReview(budgetID: "group-1", transactionID: "txn")
        )
        let draft = try edited(baseline, amount: -20_000)
        let before = try await amount(bundle)

        await #expect(throws: ReconciledTransactionMutationError.self) {
            _ = try await repository.updateTransactionAndRefresh(
                "txn", with: draft, budgetID: "group-1", originalAccountID: "checking",
                originalMonth: "2026-07", reconciliationAuthorization: nil, baseline: baseline, didUpdate: {}
            )
        }
        #expect(try await amount(bundle) == before)

        _ = try await repository.updateTransactionAndRefresh(
            "txn", with: draft, budgetID: "group-1", originalAccountID: "checking",
            originalMonth: "2026-07", reconciliationAuthorization: review.authorization,
            baseline: baseline, didUpdate: {}
        )
        #expect(try await amount(bundle) == -20_000)
    }

    @Test func protocolDeleteCarriesTheReconciliationAuthorizationToTheStore() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.reconciledFixtureSQL)
        let repository: any TransactionRepositoryProtocol = bundle.store
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let review = try #require(
            try await bundle.store.reconciledMutationReview(budgetID: "group-1", transactionID: "txn")
        )

        await #expect(throws: ReconciledTransactionMutationError.self) {
            _ = try await repository.deleteTransactionAndRefresh(
                transaction, budgetID: "group-1", reconciliationAuthorization: nil, didDelete: {}
            )
        }
        #expect(try await amount(bundle) != nil)

        _ = try await repository.deleteTransactionAndRefresh(
            transaction, budgetID: "group-1", reconciliationAuthorization: review.authorization, didDelete: {}
        )
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let tombstone = try await DatabaseQueue(path: url.path).read { db in
            try Int.fetchOne(db, sql: "SELECT tombstone FROM transactions WHERE id = 'txn'")
        }
        #expect(tombstone == 1)
    }

    @Test func protocolCategorizeCarriesTheReconciliationAuthorizationsToTheStore() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(additionalFixtureSQL: Self.reconciledFixtureSQL)
        let repository: any TransactionRepositoryProtocol = bundle.store
        let transaction = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "txn"))
        let review = try #require(
            try await bundle.store.reconciledMutationReview(budgetID: "group-1", transactionID: "txn")
        )

        await #expect(throws: ReconciledTransactionMutationError.self) {
            _ = try await repository.categorizeTransactionAndRefresh(
                transaction, categoryID: "utilities", budgetID: "group-1",
                reconciliationAuthorizations: [:], didUpdate: {}
            )
        }
        _ = try await repository.categorizeTransactionAndRefresh(
            transaction, categoryID: "utilities", budgetID: "group-1",
            reconciliationAuthorizations: ["txn": review.authorization], didUpdate: {}
        )
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let category = try await DatabaseQueue(path: url.path).read { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = 'txn'")
        }
        #expect(category == "utilities")
    }
}
