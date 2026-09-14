import Foundation

extension LocalFirstActualStore {
    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        try await requireDatabase(for: budgetID)
            .reconciledMutationReview(transactionID: transactionID)
    }

    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot {
        try await requireDatabase(for: budgetID)
            .accountReconciliationSnapshot(accountID: accountID)
    }

    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult {
        let database = try requireDatabase(for: budgetID)
        let write = try await database.createReconciliationAdjustment(
            accountID: accountID,
            targetBalance: targetBalance,
            now: Date()
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
        let write = try await database.finishReconciliation(
            accountID: accountID,
            targetBalance: targetBalance,
            now: Date()
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
        let write = try await database.exitReconciliation(
            accountID: accountID,
            now: Date()
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
        let write = try await database.unlockReconciledTransaction(
            accountID: accountID,
            transactionID: transactionID,
            now: Date()
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
            try await reloadAfterTransactionMutation(
                database: database,
                budgetID: budgetID,
                accountIDs: write.changed.accounts,
                monthIDs: write.changed.months
            )
            await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        }
        let snapshot = try await database.accountReconciliationSnapshot(accountID: accountID)
        return AccountReconciliationMutationResult(snapshot: snapshot, changed: write.changed)
    }
}
