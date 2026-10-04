import Foundation

@MainActor
protocol SavedTransactionFilterRepositoryProtocol: AnyObject {
    func refreshSavedTransactionFilters(budgetID: String) async throws -> SavedTransactionFilterReadResult
    func createSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        draft: SavedTransactionFilterDraft
    ) async throws -> SavedTransactionFilterMutationResult
    func updateSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        update: SavedTransactionFilterUpdate
    ) async throws -> SavedTransactionFilterMutationResult
    func deleteSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        filterID: String
    ) async throws -> SavedTransactionFilterMutationResult
}
