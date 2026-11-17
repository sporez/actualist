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
/// `refreshPending` instead of turning a durable write into a failed one.
///
/// The tail rule: a write that has committed is never reported
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
                try await rules.refreshRulesAndPayeesAfterLearning(
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

    /// Recompute the selected month even for backdated writes; its balance may
    /// depend on any earlier rollover month. External reads do not change selection.
    func reloadSelectedBudgetCache(budgetID: String, now: Date = Date()) async throws {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        schedules.invalidateScheduleCache(budgetID: budgetID)
        budgetReadGeneration &+= 1
        cachePublicationRevision &+= 1
        let publicationRevision = cachePublicationRevision
        monthsByBudget[budgetID] = nil
        templateBrowserByBudget[budgetID] = nil
        let prefix = "\(budgetID)|"
        // Open feeds observe these snapshots directly. Replace their contents
        // after a write instead of evicting them until the screen is reopened.
        let categoryScopes = categoryTransactionsByKey.keys.filter { $0.hasPrefix(prefix) }.compactMap { key in
            let scope = key.dropFirst(prefix.count).split(separator: "|", maxSplits: 1)
            return scope.count == 2 ? (categoryID: String(scope[0]), month: String(scope[1])) : nil
        }
        let uncategorizedMonths = uncategorizedTransactionsByKey.keys.filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        // One name-map read and one table read serve every cached feed.
        if !categoryScopes.isEmpty || !uncategorizedMonths.isEmpty {
            let maps = try await TransactionReadSQL.nameMaps(database)
            if !categoryScopes.isEmpty {
                let transactions = try await TransactionReadSQL.fetchTransactions(in: database)
                for scope in categoryScopes {
                    try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
                    publishCategoryTransactions(
                        budgetID: budgetID, categoryID: scope.categoryID, month: scope.month,
                        allTransactions: transactions, maps: maps
                    )
                }
            }
            if !uncategorizedMonths.isEmpty {
                let rows = try await TransactionReadSQL.fetchUncategorizedTransactions(in: database)
                for month in uncategorizedMonths {
                    _ = try await publishUncategorizedTransactions(
                        database: database, budgetID: budgetID, month: month,
                        generation: generation, revision: publicationRevision, rows: rows, maps: maps
                    )
                }
            }
            try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        }
        guard let selected = loadedBudgetMonthsByBudget[budgetID]?.selectedMonth else { return }
        let loaded = try await readBudgetMonth(budgetID: budgetID, month: selected, now: now)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard loadedBudgetMonthsByBudget[budgetID]?.selectedMonth == selected else { return }
        loadedBudgetMonthsByBudget[budgetID] = loaded
        currencyByBudget[budgetID] = loaded.currency
    }

    func reloadAccountCaches(
        database: BudgetDatabase,
        budgetID: String,
        bestEffort: Bool = false
    ) async throws {
        let generation = budgetSessionGeneration
        let accounts: [AccountDisplay]?
        if bestEffort { accounts = try? await AccountSQL.fetchAccountDisplays(in: database) }
        else { accounts = try await AccountSQL.fetchAccountDisplays(in: database) }
        #if DEBUG
        #if DEBUG
        if bestEffort { await testSeams?.launchWarmupSuspension?() }
        #endif
        #endif
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if let accounts { accountsByBudget[budgetID] = accounts }
        let groups: [ActualAccountGroup]?
        if bestEffort { groups = try? await AccountGroupSQL.fetchAccountGroups(in: database) }
        else { groups = try await AccountGroupSQL.fetchAccountGroups(in: database) }
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        if let groups { accountGroupsByBudget[budgetID] = groups }
    }

    func reloadAfterTransactionMutation(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: [String]
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        reports.invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        try await refreshLoadedTransactionFeedCaches(
            database: database,
            budgetID: budgetID,
            accountIDs: Set(accountIDs)
        )
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    func reloadAfterBudgetMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        reports.invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    func reloadAfterAccountMutation(
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        try await reloadSelectedBudgetCache(budgetID: budgetID)
        reports.invalidateReports(budgetID: budgetID)
        try await reloadAccountCaches(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }
}
