import Foundation

extension LocalFirstActualStore {
    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        try await ReconciledMutationReviewSQL.reconciledMutationReview(
            transactionID: transactionID,
            in: requireDatabase(for: budgetID)
        )
    }

    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        try await ReconciliationSQL.accountReconciliationSnapshot(
            accountID: accountID,
            in: requireDatabase(for: budgetID)
        )
    }

    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        let database = try requireDatabase(for: budgetID)
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
        let database = try requireDatabase(for: budgetID)
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
        let database = try requireDatabase(for: budgetID)
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

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        let database = try requireDatabase(for: budgetID)
        let write = try await ReconciliationSQL.unlockReconciledTransaction(
            accountID: accountID,
            transactionID: transactionID,
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

    private func finishReconciliationWrite(
        _ write: AccountReconciliationDatabaseWrite,
        database: BudgetDatabase,
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult {
        if write.committed {
            try await finishCommittedTransactionWrite(
                database: database,
                budgetID: budgetID,
                accountIDs: write.changed.accounts
            )
        }
        let snapshot = try await ReconciliationSQL.accountReconciliationSnapshot(accountID: accountID, in: database)
        return AccountReconciliationMutationResult(snapshot: snapshot, changed: write.changed)
    }
}
