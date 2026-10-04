import Foundation

typealias SavedFilterMutationHook = @MainActor @Sendable () async -> Void

extension LocalFirstActualStore {
    func refreshSavedTransactionFilters(budgetID: String) async throws -> SavedTransactionFilterReadResult {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        nextSavedTransactionFilterReadRevision &+= 1
        let revision = nextSavedTransactionFilterReadRevision
        savedTransactionFilterReadRevisionByBudget[budgetID] = revision
        let result = try await database.fetchSavedTransactionFilters()
        try requireSavedFilterSession(database: database, budgetID: budgetID, generation: generation)
        guard savedTransactionFilterReadRevisionByBudget[budgetID] == revision else {
            throw CancellationError()
        }
        savedTransactionFiltersByBudget[budgetID] = result
        return result
    }

    func createSavedTransactionFilter(
        context: SavedTransactionFilterMutationContext,
        draft: SavedTransactionFilterDraft
    ) async throws -> SavedTransactionFilterMutationResult {
        let database = try requireSavedFilterMutationSession(context)
        var builder = LocalFirstSyncMessageBuilder()
        await savedFilterBeforeCommitHook?()
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await database.createSavedTransactionFilter(
            id: UUID().uuidString,
            draft: draft,
            builder: &builder
        )
        await awaitSavedFilterAfterCommitHook()
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
        await savedFilterBeforeCommitHook?()
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await database.updateSavedTransactionFilter(update, builder: &builder)
        await awaitSavedFilterAfterCommitHook()
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
        await savedFilterBeforeCommitHook?()
        try requireSavedFilterSession(database: database, context: context)
        let receipt = try await database.deleteSavedTransactionFilter(id: filterID, builder: &builder)
        await awaitSavedFilterAfterCommitHook()
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
        await Task { @MainActor [self] in
            do {
                try requireSavedFilterSession(database: database, context: context)
                let refreshed = try await refreshSavedTransactionFilters(budgetID: context.budgetID)
                try requireSavedFilterSession(database: database, context: context)
                guard case .available(let filters) = refreshed else {
                    return SavedTransactionFilterMutationResult(
                        filters: nil,
                        changed: receipt.changed,
                        appliedMessageCount: receipt.appliedMessageCount,
                        refreshPending: true,
                        sessionCurrent: true
                    )
                }
                if receipt.changed {
                    await schedulePendingLocalMessageFlush(database: database, budgetID: context.budgetID)
                    try requireSavedFilterSession(
                        database: database, context: context
                    )
                }
                return SavedTransactionFilterMutationResult(
                    filters: filters,
                    changed: receipt.changed,
                    appliedMessageCount: receipt.appliedMessageCount,
                    refreshPending: false,
                    sessionCurrent: true
                )
            } catch {
                var sessionCurrent = (try? requireSavedFilterSession(
                    database: database, context: context
                )) != nil
                if sessionCurrent, receipt.changed {
                    await schedulePendingLocalMessageFlush(database: database, budgetID: context.budgetID)
                    sessionCurrent = (try? requireSavedFilterSession(
                        database: database, context: context
                    )) != nil
                }
                return SavedTransactionFilterMutationResult(
                    filters: nil,
                    changed: receipt.changed,
                    appliedMessageCount: receipt.appliedMessageCount,
                    refreshPending: true,
                    sessionCurrent: sessionCurrent
                )
            }
        }.value
    }

    private func awaitSavedFilterAfterCommitHook() async {
        guard let hook = savedFilterAfterCommitHook else { return }
        await Task { @MainActor in await hook() }.value
    }

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
        guard self.database === database,
              openedBudgetID == budgetID,
              budgetSessionGeneration == generation else {
            throw CancellationError()
        }
    }

    private func requireSavedFilterMutationSession(
        _ context: SavedTransactionFilterMutationContext
    ) throws -> BudgetDatabase {
        guard openedBudgetID == context.budgetID,
              budgetSessionGeneration == context.generation else {
            throw CancellationError()
        }
        let database = try requireDatabase(for: context.budgetID)
        try requireSavedFilterSession(database: database, context: context)
        return database
    }
}
