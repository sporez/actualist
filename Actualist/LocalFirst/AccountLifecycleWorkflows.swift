import Foundation

/// Account close, delete, rename and reopen on the store: the review and the
/// commit with its durable tail. The store owns it; the account caches and
/// the action-log snapshot stay on the store, which publishes them.
@MainActor
final class AccountLifecycleWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func accountLifecycleReview(
        request: AccountLifecycleReviewRequest
    ) async throws -> AccountLifecycleReview {
        let database = try store.requireDatabase(for: request.budgetID)
        let generation = store.budgetSessionGeneration
        let review = try await AccountLifecycleReviewSQL.accountLifecycleReview(request: request, in: database)
        try store.requireSyncSession(database: database, budgetID: request.budgetID, generation: generation)
        return review
    }

    func renameAccountAndRefresh(
        budgetID: String,
        command: AccountRenameCommand
    ) async throws -> AccountLifecycleMutationResult {
        try await applyAccountLifecycle(.rename(command), budgetID: budgetID)
    }

    func reopenAccountAndRefresh(
        budgetID: String,
        command: AccountReopenCommand
    ) async throws -> AccountLifecycleMutationResult {
        try await applyAccountLifecycle(.reopen(command), budgetID: budgetID)
    }

    func commitAccountLifecycleAndRefresh(
        reviewed: AccountLifecycleReview
    ) async throws -> AccountLifecycleCommitResult {
        try Task.checkCancellation()
        let budgetID = reviewed.identity.budgetID
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let result = try await AccountLifecycleCommitSQL.commitAccountLifecycleReview(reviewed, in: database)
        if case .reviewChanged = result {
            return result
        }
        let unlinkedAccountID: String?
        if case .applied = result, reviewed.bankLink?.provider == .simpleFIN {
            unlinkedAccountID = reviewed.account.id
        } else {
            unlinkedAccountID = nil
        }
        return await finishAccountLifecycleCommit(
            result,
            database: database,
            budgetID: budgetID,
            generation: generation,
            unlinkedAccountID: unlinkedAccountID
        )
    }

    private func applyAccountLifecycle(
        _ command: AccountLifecycleMutationPrecondition,
        budgetID: String
    ) async throws -> AccountLifecycleMutationResult {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let result = try await AccountLifecycleCommitSQL.commitAccountLifecycleMutation(command, in: database)

        return await finishAccountLifecycleCommit(
            result,
            database: database,
            budgetID: budgetID,
            generation: generation,
            unlinkedAccountID: nil
        )
    }

    private func finishAccountLifecycleCommit<Result: AccountLifecycleRefreshMarkable>(
        _ result: Result,
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        unlinkedAccountID: String?
    ) async -> Result {
        // A committed account change is durable. Cancellation or refresh failure
        // must not turn it into a failed write that the UI invites the user to repeat.
        let tail = await store.finishDurableCommit(
            database: database,
            budgetID: budgetID,
            invalidatesFeedCachesOnFailure: false,
            requireSession: { [self] in
                try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            },
            reload: { [self] in
                if let unlinkedAccountID {
                    store.bankSyncGenerationByAccount[unlinkedAccountID] = nil
                }
                try await store.reloadSelectedBudgetCache(budgetID: budgetID)
                try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                store.reports.invalidateReports(budgetID: budgetID)
                try await store.reloadAccountCaches(database: database, budgetID: budgetID)
                try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                try await store.transactions.refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
                try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                let diagnostics = try await ActionLogStorageSQL.actionLogDiagnosticSnapshot(in: database)
                try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                store.actionLogDiagnosticSnapshot = diagnostics
            }
        )
        return tail.refreshPending ? result.markingRefreshPending() : result
    }
}

extension AccountLifecycleWorkflows: AccountLifecycleRepositoryProtocol { }
