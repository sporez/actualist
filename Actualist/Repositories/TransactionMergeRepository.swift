import Foundation

/// Repository boundary for a later database/store review and atomic commit.
/// Implementations load validated graph snapshots; callers supply only ordered
/// persisted IDs and never receive SQL or transport concerns.
@MainActor
protocol TransactionMergeRepositoryProtocol: AnyObject {
    func reviewTransactionMerge(
        context: TransactionSelectionContext,
        orderedTransactionIDs: [String]
    ) async throws -> TransactionMergeReview

    func commitTransactionMerge(
        review: TransactionMergeReview,
        authorization: TransactionMergeAuthorization?
    ) async throws -> TransactionMergeOutcome
}
