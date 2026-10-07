import Foundation

/// What a durable commit tail reports once the database write has landed.
struct DurableCommitTailOutcome<Value: Sendable>: Sendable {
    /// The value the reload produced. Nil when the refresh did not complete.
    let value: Value?
    /// The write is durable but the local caches may not reflect it yet.
    let refreshPending: Bool
    /// The session that issued the write is still the open one.
    let sessionCurrent: Bool
}

/// The post-commit tail every local write shares: reload the affected caches,
/// then schedule an outbox flush. The flush is scheduled even when the reload
/// fails, because the committed messages are already enqueued and must still
/// reach the server. A failed or cancelled reload is reported as
/// `refreshPending` (D9a) instead of turning a durable write into a failed one.
///
/// The tail rule (main-to-dev D9): a write that has committed is never reported
/// as cancelled or failed, whichever tail it uses.
/// - User-repeatable writes (create, update, delete, categorize, assign, Move
///   Money, Holds, Wallet import) finish through `finishDurableCommit`, whose
///   unstructured MainActor task keeps caller cancellation out of the reload
///   and the post-commit read, so the caller always gets the committed result
///   (or `refreshPending`) and its draft is spent. Repeating one of these
///   writes would duplicate it.
/// - Idempotent last-write-wins writes (notes, hide, rename, payee and rule
///   edits, carryover, templates) keep the attached tail below. Repeating one
///   re-sends the same final value, so a cancelled reload only costs a stale
///   cache, reported as `refreshPending`.
/// - `ScheduleAdvancement` keeps its own tail: it runs in the background and
///   has no caller to attach to.
extension LocalFirstActualStore {
    /// Tail for last-write-wins writes that return to a still-attached caller.
    ///
    /// Any reload failure, including cancellation, invalidates the feed caches
    /// so the next read repopulates them, flushes, and returns `true`.
    /// Cancellation is not rethrown: the write is durable.
    ///
    /// - Returns: `true` when the write committed but the refresh is pending.
    @discardableResult
    func finishCommittedWrite(
        database: BudgetDatabase,
        budgetID: String,
        reload: () async throws -> Void
    ) async throws -> Bool {
        do {
            try await reload()
        } catch {
            invalidateTransactionFeedCaches(budgetID: budgetID)
            await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
            return true
        }
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return false
    }

    /// `finishCommittedWrite` for the transaction reload scope.
    @discardableResult
    func finishCommittedTransactionWrite(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String]
    ) async throws -> Bool {
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterTransactionMutation(
                database: database,
                budgetID: budgetID,
                accountIDs: accountIDs
            )
        }
    }

    /// `finishCommittedWrite` for the budget-wide reload scope.
    @discardableResult
    func finishCommittedBudgetWrite(database: BudgetDatabase, budgetID: String) async throws -> Bool {
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
        }
    }

    /// `finishCommittedWrite` for the account reload scope.
    @discardableResult
    func finishCommittedAccountWrite(database: BudgetDatabase, budgetID: String) async throws -> Bool {
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        }
    }

    /// Tail for durable receipts that must survive caller cancellation and
    /// session retirement. An unstructured MainActor task owns publication, so
    /// the caller can neither erase nor misreport the commit.
    ///
    /// `requireSession` throws when the issuing session is gone. It runs before
    /// the reload and after the flush; `reload` places its own checks between
    /// awaited steps. After any failure the flush is still scheduled while the
    /// session is current. `invalidatesFeedCachesOnFailure` and `flushes` keep
    /// the per-site differences explicit.
    func finishDurableCommit<Value: Sendable>(
        database: BudgetDatabase,
        budgetID: String,
        flushes: Bool = true,
        invalidatesFeedCachesOnFailure: Bool = true,
        requireSession: @escaping @MainActor () throws -> Void,
        reload: @escaping @MainActor () async throws -> Value
    ) async -> DurableCommitTailOutcome<Value> {
        await Task { @MainActor [self] in
            do {
                try requireSession()
                let value = try await reload()
                try requireSession()
                if flushes {
                    await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
                    try requireSession()
                }
                return DurableCommitTailOutcome(value: value, refreshPending: false, sessionCurrent: true)
            } catch {
                var sessionCurrent = (try? requireSession()) != nil
                if sessionCurrent {
                    if invalidatesFeedCachesOnFailure {
                        invalidateTransactionFeedCaches(budgetID: budgetID)
                    }
                    if flushes {
                        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
                        sessionCurrent = (try? requireSession()) != nil
                    }
                }
                return DurableCommitTailOutcome(value: nil, refreshPending: true, sessionCurrent: sessionCurrent)
            }
        }.value
    }

    /// `finishDurableCommit` for the transaction reload scope, bound to the
    /// session generation captured when the write began.
    func finishDurableTransactionWrite(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        accountIDs: [String],
        learningIDs: Set<String> = []
    ) async -> DurableCommitTailOutcome<Void> {
        await finishDurableCommit(
            database: database,
            budgetID: budgetID,
            requireSession: { [self] in
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
            },
            reload: { [self] in
                try await refreshRulesAndPayeesAfterLearning(
                    learningIDs: learningIDs,
                    database: database,
                    budgetID: budgetID
                )
                try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                try await reloadAfterTransactionMutation(
                    database: database,
                    budgetID: budgetID,
                    accountIDs: accountIDs
                )
            }
        )
    }

    /// `finishDurableCommit` for the budget reload scope. The reloaded month is
    /// read inside the durable task so a cancelled caller cannot lose it.
    ///
    /// - Returns: The month, or nil when the write committed but the refresh is
    ///   pending (a failed read or a retired session).
    func finishDurableBudgetWrite(
        database: BudgetDatabase,
        budgetID: String,
        generation: Int,
        month: String
    ) async -> LoadedBudgetMonth? {
        let requireSession: @MainActor () throws -> Void = { [self] in
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }
        let tail: DurableCommitTailOutcome<LoadedBudgetMonth> = await finishDurableCommit(
            database: database,
            budgetID: budgetID,
            requireSession: requireSession,
            reload: { [self] in
                try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
                try requireSession()
                return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
            }
        )
        return tail.value
    }
}
