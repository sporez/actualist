import Foundation

protocol AccountLifecycleRepositoryProtocol: Sendable {
    @MainActor
    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview

    @MainActor
    func renameAccountAndRefresh(
        budgetID: String,
        command: AccountRenameCommand
    ) async throws -> AccountLifecycleMutationResult

    @MainActor
    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleMutationResult

    @MainActor
    func commitAccountLifecycleAndRefresh(
        reviewed: AccountLifecycleReview
    ) async throws -> AccountLifecycleCommitResult
}
