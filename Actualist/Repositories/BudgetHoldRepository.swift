import Foundation

/// Hold for next month: the review of a hold or release and its write.
protocol BudgetHoldRepositoryProtocol: Sendable {
    func budgetHoldReview(budgetID: String, month: String) async throws -> BudgetHoldReview
    func applyBudgetHoldAndRefresh(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        budgetID: String
    ) async throws -> LoadedBudgetMonth?
}
