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
/// reach the server. A failed reload is reported as `refreshPending` (D9a)
/// instead of turning a durable write into a failed one.
extension LocalFirstActualStore {
    /// Tail for writes that return to a still-attached caller.
    ///
    /// Reload failures other than cancellation return `true` after invalidating
    /// the feed caches so the next read repopulates them. Cancellation still
    /// flushes, then propagates as cancellation.
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
        } catch is CancellationError {
            await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
            throw CancellationError()
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
        accountIDs: [String],
        monthIDs: [String]
    ) async throws -> Bool {
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterTransactionMutation(
                database: database,
                budgetID: budgetID,
                accountIDs: accountIDs,
                monthIDs: monthIDs
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
}
