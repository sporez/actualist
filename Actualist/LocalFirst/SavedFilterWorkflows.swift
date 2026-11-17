import Foundation

/// Saved transaction filters on the store: the cached list's refresh and its
/// request revisions, and create, update and delete with their durable tail.
/// The store owns it; the filter cache (`savedTransactionFiltersByBudget`)
/// stays on the store, which publishes it.
@MainActor
final class SavedFilterWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore
    private var savedTransactionFilterReadRevisionByBudget: [String: UInt64] = [:]
    private var nextSavedTransactionFilterReadRevision: UInt64 = 0

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// Called where the store clears its budget session.
    func resetRequestSession() { savedTransactionFilterReadRevisionByBudget = [:] }

    func refreshSavedTransactionFilters(budgetID: String) async throws -> SavedTransactionFilterReadResult {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        nextSavedTransactionFilterReadRevision &+= 1
        let revision = nextSavedTransactionFilterReadRevision
        savedTransactionFilterReadRevisionByBudget[budgetID] = revision
        let result = try await SavedFilterSQL.fetchSavedTransactionFilters(in: database)
        try requireSavedFilterSession(database: database, budgetID: budgetID, generation: generation)
        guard savedTransactionFilterReadRevisionByBudget[budgetID] == revision else {
            throw CancellationError()
        }
        store.savedTransactionFiltersByBudget[budgetID] = result
        return result
    }

    func createSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        draft: SavedTransactionFilterDraft
    ) async throws -> SavedTransactionFilterMutationResult {
        let database = try requireSavedFilterMutationSession(context)
        var builder = LocalFirstSyncMessageBuilder()
        #if DEBUG
        await store.testSeams?.savedFilterBeforeCommitHook?()
        #endif
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await SavedFilterSQL.createSavedTransactionFilter(
            id: UUID().uuidString,
            draft: draft,
            builder: &builder,
            in: database
        )
        #if DEBUG
        await awaitSavedFilterAfterCommitHook()
        #endif
        return await finishSavedTransactionFilterMutation(
            receipt: receipt, database: database, context: context
        )
    }

    func updateSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        update: SavedTransactionFilterUpdate
    ) async throws -> SavedTransactionFilterMutationResult {
        let database = try requireSavedFilterMutationSession(context)
        var builder = LocalFirstSyncMessageBuilder()
        #if DEBUG
        await store.testSeams?.savedFilterBeforeCommitHook?()
        #endif
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await SavedFilterSQL.updateSavedTransactionFilter(update, builder: &builder, in: database)
        #if DEBUG
        await awaitSavedFilterAfterCommitHook()
        #endif
        return await finishSavedTransactionFilterMutation(
            receipt: receipt, database: database, context: context
        )
    }

    func deleteSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        filterID: String
    ) async throws -> SavedTransactionFilterMutationResult {
        let database = try requireSavedFilterMutationSession(context)
        var builder = LocalFirstSyncMessageBuilder()
        #if DEBUG
        await store.testSeams?.savedFilterBeforeCommitHook?()
        #endif
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await SavedFilterSQL.deleteSavedTransactionFilter(id: filterID, builder: &builder, in: database)
        #if DEBUG
        await awaitSavedFilterAfterCommitHook()
        #endif
        return await finishSavedTransactionFilterMutation(
            receipt: receipt, database: database, context: context
        )
    }

    private func finishSavedTransactionFilterMutation(
        receipt: SavedTransactionFilterCommitReceipt,
        database: BudgetDatabase,
        context: SavedTransactionFilterMutationContext
    ) async -> SavedTransactionFilterMutationResult {
        // The commit receipt is already durable; caller cancellation or session
        // retirement may only affect refresh/publication, never report save failure.
        let tail: DurableCommitTailOutcome<[SavedTransactionFilter]> = await store.finishDurableCommit(
            database: database,
            budgetID: context.budgetID,
            flushes: receipt.changed,
            invalidatesFeedCachesOnFailure: false,
            requireSession: { [self] in try requireSavedFilterSession(database: database, context: context) },
            reload: { [self] in
                guard case .available(let filters) = try await refreshSavedTransactionFilters(budgetID: context.budgetID) else {
                    throw SavedFilterRefreshUnavailable()
                }
                return filters
            }
        )
        return SavedTransactionFilterMutationResult(
            filters: tail.value,
            changed: receipt.changed,
            appliedMessageCount: receipt.appliedMessageCount,
            refreshPending: tail.refreshPending,
            sessionCurrent: tail.sessionCurrent
        )
    }

    #if DEBUG
    private func awaitSavedFilterAfterCommitHook() async {
        guard let hook = store.testSeams?.savedFilterAfterCommitHook else { return }
        await Task { @MainActor in await hook() }.value
    }
    #endif

    private func requireSavedFilterSession(
        database: BudgetDatabase,
        context: SavedTransactionFilterMutationContext
    ) throws {
        try requireSavedFilterSession(
            database: database,
            budgetID: context.budgetID,
            generation: context.generation
        )
    }

    private func requireSavedFilterSession(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int
    ) throws {
        guard store.database === database,
              store.openedBudgetID == budgetID,
              store.budgetSessionGeneration == generation else {
            throw CancellationError()
        }
    }

    private func requireSavedFilterMutationSession(
        _ context: SavedTransactionFilterMutationContext
    ) throws -> BudgetDatabase {
        guard store.openedBudgetID == context.budgetID,
              store.budgetSessionGeneration == context.generation else {
            throw CancellationError()
        }
        let database = try store.requireDatabase(for: context.budgetID)
        try requireSavedFilterSession(database: database, context: context)
        return database
    }
}

extension SavedFilterWorkflows: SavedTransactionFilterRepositoryProtocol { }

/// The refresh after a committed saved-filter write could not read the filters.
private struct SavedFilterRefreshUnavailable: Error {}
