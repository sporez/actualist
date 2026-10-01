import Foundation

@MainActor
protocol TransactionBatchRepositoryProtocol: AnyObject {
    func reviewTransactionBatch(
        context: TransactionSelectionContext,
        intent: TransactionBatchIntent,
        selections: [TransactionSelectionIdentity],
        loadedUngroupedTransactionIDs: [String]
    ) async throws -> TransactionBatchReview

    func commitTransactionBatch(
        review: TransactionBatchReview,
        authorization: TransactionBatchAuthorization?
    ) async throws -> TransactionBatchOutcome
}
