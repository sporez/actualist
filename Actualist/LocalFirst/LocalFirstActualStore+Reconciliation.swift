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
        return try await reconciliation.finishReconciliationWrite(
            write,
            database: database,
            budgetID: budgetID,
            accountID: accountID
        )
    }
}
