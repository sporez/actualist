import Foundation

/// Account reconciliation: the snapshot of a reconciliation session and the
/// writes that adjust, finish or exit it.
protocol AccountReconciliationRepositoryProtocol: Sendable {
    @MainActor
    func accountReconciliationSnapshot(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationSnapshot

    @MainActor
    func createReconciliationAdjustmentAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func finishReconciliationAndRefresh(
        budgetID: String,
        accountID: String,
        targetBalance: Int
    ) async throws -> AccountReconciliationMutationResult

    @MainActor
    func exitReconciliationAndRefresh(
        budgetID: String,
        accountID: String
    ) async throws -> AccountReconciliationMutationResult
}
