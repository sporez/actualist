import Foundation

/// Account reconciliation on the store: the session snapshot and the
/// adjustment, finish and exit writes with the reload that follows. The store
/// owns it and keeps the transaction unlock, which the transaction editor
/// reaches through the transaction repository.
@MainActor
final class ReconciliationWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        try await ReconciliationSQL.accountReconciliationSnapshot(
            accountID: accountID,
            in: store.requireDatabase(for: budgetID)
        )
    }

    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let write = try await ReconciliationSQL.createReconciliationAdjustment(
            accountID: accountID,
            targetBalance: targetBalance,
            now: Date(),
            in: database
        )
        return try await finishReconciliationWrite(
            write,
            database: database,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    func finishReconciliationAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let write = try await ReconciliationSQL.finishReconciliation(
            accountID: accountID,
            targetBalance: targetBalance,
            now: Date(),
            in: database
        )
        return try await finishReconciliationWrite(
            write,
            database: database,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    func exitReconciliationAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let write = try await ReconciliationSQL.exitReconciliation(
            accountID: accountID,
            now: Date(),
            in: database
        )
        return try await finishReconciliationWrite(
            write,
            database: database,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    func finishReconciliationWrite(
        _ write: AccountReconciliationDatabaseWrite,
        database: BudgetDatabase,
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult {
        if write.committed {
            try await store.finishCommittedTransactionWrite(
                database: database,
                budgetID: budgetID,
                accountIDs: write.changed.accounts
            )
        }
        let snapshot = try await ReconciliationSQL.accountReconciliationSnapshot(accountID: accountID, in: database)
        return AccountReconciliationMutationResult(snapshot: snapshot, changed: write.changed)
    }
}

extension ReconciliationWorkflows: AccountReconciliationRepositoryProtocol { }
