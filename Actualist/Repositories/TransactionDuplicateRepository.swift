import Foundation

@MainActor
protocol TransactionDuplicateRepositoryProtocol: AnyObject {
    func reviewTransactionDuplicate(
        context: TransactionSelectionContext,
        selections: [TransactionSelectionIdentity]
    ) async throws -> TransactionDuplicateReview

    func commitTransactionDuplicate(
        review: TransactionDuplicateReview
    ) async throws -> TransactionDuplicateOutcome
}
