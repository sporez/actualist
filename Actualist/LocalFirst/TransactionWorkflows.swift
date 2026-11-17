import Foundation

/// The transaction repository on the store: the account and Spending feeds
/// with their page cache refresh, the category and uncategorized feeds, the
/// transaction writes, the editor reads and Wallet import. The store owns it;
/// the observed feed caches and their reload tail stay on the store, which
/// other domains' writes also refresh. Only the store creates it, so the
/// refresh gate has one instance.
@MainActor
final class TransactionWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore
    private typealias TransactionFeedPage = LocalFirstActualStore.TransactionFeedPage

    let transactionPageSize = 100
    private let transactionFeedCacheRefreshGate = TransactionFeedCacheRefreshGate()
    /// Identifies each feed read so a superseded or pre-reset read cannot publish.
    private(set) var feedRequestIdentity = TransactionFeedRequestIdentity()

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func resetRequestSession() { feedRequestIdentity.resetSession() }

    func cachedTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) -> LoadedAccountTransactions? {
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        return store.transactionFeedPagesByKey[key]?.loaded
    }

    func refreshTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        try await refreshTransactionFeed(key: key, database: database)
    }

    func refreshTransactionFeed(
        key: TransactionFeedCacheKey,
        database: BudgetDatabase
    ) async throws {
        let ticket = feedRequestIdentity.begin(for: key)
        let limit = max(store.transactionFeedPagesByKey[key]?.nextOffset ?? transactionPageSize, transactionPageSize)
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: key.budgetID,
            key: key,
            limit: limit,
            offset: 0
        )
        guard commitTransactionFeedPage(loaded, ticket: ticket, database: database, budgetID: key.budgetID) else {
            throw CancellationError()
        }
    }

    func loadOlderTransactions(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        try await loadOlderTransactionFeed(key: key, database: database)
    }

    func loadOlderTransactionFeed(
        key: TransactionFeedCacheKey,
        database: BudgetDatabase
    ) async throws {
        guard let current = store.transactionFeedPagesByKey[key] else {
            try await refreshTransactionFeed(key: key, database: database)
            return
        }
        guard !current.loaded.reachedEnd else { return }

        let ticket = feedRequestIdentity.begin(for: key)
        let older = try await loadTransactionFeedPage(
            database: database,
            budgetID: key.budgetID,
            key: key,
            limit: transactionPageSize,
            offset: current.nextOffset
        )
        guard feedRequestIdentity.accepts(ticket),
              store.database === database,
              store.openedBudgetID == key.budgetID,
              store.transactionFeedPagesByKey[key]?.nextOffset == current.nextOffset else {
            throw CancellationError()
        }
        store.transactionFeedPagesByKey[key] = TransactionFeedPage(
            loaded: current.loaded.appendingPage(older)
        )
    }

    func transactionPage(
        budgetID: String,
        scope: TransactionQueryScope,
        query: TransactionFeedQuery,
        limit: Int,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        let database = try store.requireDatabase(for: budgetID)
        let sessionID = feedRequestIdentity.sessionID
        let key = TransactionFeedCacheKey(budgetID: budgetID, queryScope: scope, query: query)
        let loaded = try await loadTransactionFeedPage(
            database: database,
            budgetID: budgetID,
            key: key,
            limit: limit,
            offset: offset
        )
        guard feedRequestIdentity.sessionID == sessionID,
              store.database === database,
              store.openedBudgetID == budgetID else {
            throw CancellationError()
        }
        return loaded
    }

    func loadTransactionFeedPage(
        database: BudgetDatabase,
        budgetID: String,
        key: TransactionFeedCacheKey,
        limit: Int?,
        offset: Int
    ) async throws -> LoadedAccountTransactions {
        #if DEBUG
        try await store.testSeams?.transactionFeedPageReadHook?(key, key.query.text, limit, offset)
        #endif
        switch key.scope {
        case .account(let accountID):
            return try await loadedAccountTransactions(
                database: database,
                budgetID: budgetID,
                accountID: accountID,
                query: key.query,
                limit: limit,
                offset: offset
            )
        case .spending:
            return try await loadedSpendingTransactions(
                database: database,
                budgetID: budgetID,
                query: key.query,
                limit: limit,
                offset: offset
            )
        }
    }

    func commitTransactionFeedPage(
        _ loaded: LoadedAccountTransactions,
        ticket: TransactionFeedRequestIdentity.Ticket,
        database: BudgetDatabase,
        budgetID: String
    ) -> Bool {
        guard feedRequestIdentity.accepts(ticket),
              store.database === database,
              store.openedBudgetID == budgetID else { return false }
        store.transactionFeedPagesByKey[ticket.key] = TransactionFeedPage(loaded: loaded)
        return true
    }

    func loadedAccountTransactions(
        database: BudgetDatabase,
        budgetID: String,
        accountID: String,
        query: TransactionFeedQuery,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await TransactionReadSQL.nameMaps(database)
        let accountPage = try await TransactionQuerySQL.fetchAccountTransactionQueryPage(
            accountID: accountID,
            query: query,
            limit: limit,
            offset: offset,
            in: database
        )
        let page = accountPage.page
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: accountPage.balance,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd,
            nextOffset: page.nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: page.totalMatchCount,
                querySignature: page.querySignature,
                matchingTransactionIDs: page.matchingTransactionIDs,
                contributingTransactionIDs: page.contributingTransactionIDs,
                attachedContextTransactionIDs: page.attachedContextTransactionIDs
            ),
            runningBalanceSetting: accountPage.runningBalanceSetting
        )
    }

    func loadedSpendingTransactions(
        database: BudgetDatabase,
        budgetID: String,
        query: TransactionFeedQuery,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> LoadedAccountTransactions {
        let maps = try await TransactionReadSQL.nameMaps(database)
        let page = try await TransactionQuerySQL.fetchTransactionQueryPage(
            scope: .spending,
            query: query,
            limit: limit,
            offset: offset,
            in: database
        )
        return LoadedAccountTransactions(
            transactions: page.transactions,
            balance: nil,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            reachedEnd: page.reachedEnd,
            nextOffset: page.nextOffset,
            queryMetadata: TransactionQueryPageMetadata(
                totalMatchCount: page.totalMatchCount,
                querySignature: page.querySignature,
                matchingTransactionIDs: page.matchingTransactionIDs,
                contributingTransactionIDs: page.contributingTransactionIDs,
                attachedContextTransactionIDs: page.attachedContextTransactionIDs
            )
        )
    }

    func invalidateTransactionFeedCaches(budgetID: String) {
        let cachedKeys = Set(store.transactionFeedPagesByKey.keys.filter { $0.budgetID == budgetID })
        let inFlightKeys = feedRequestIdentity.keys(forBudget: budgetID)
        for key in cachedKeys.union(inFlightKeys) {
            _ = feedRequestIdentity.begin(for: key)
        }
        for key in cachedKeys {
            store.transactionFeedPagesByKey.removeValue(forKey: key)
        }
    }

    /// Refresh all cached account pages and Spending as one publication. A newer
    /// read for any member invalidates the whole candidate so a mutation cannot
    /// leave a partly old collection of observed filters.
    func refreshLoadedTransactionFeedCaches(
        database: BudgetDatabase,
        budgetID: String,
        accountIDs: Set<String>? = nil
    ) async throws {
        await transactionFeedCacheRefreshGate.acquire()
        defer { transactionFeedCacheRefreshGate.release() }

        while true {
            try Task.checkCancellation()
            guard store.database === database, store.openedBudgetID == budgetID else {
                throw CancellationError()
            }
            var keys = Set(store.transactionFeedPagesByKey.keys.filter { $0.budgetID == budgetID })
            keys.formUnion(feedRequestIdentity.keys(forBudget: budgetID))
            if let accountIDs {
                keys.formUnion(accountIDs.map { .account(budgetID: budgetID, accountID: $0) })
            }
            let orderedKeys = keys.sorted(by: transactionFeedCacheKeyOrder)
            let sessionID = feedRequestIdentity.sessionID
            let tickets = orderedKeys.map { feedRequestIdentity.begin(for: $0) }
            var refreshedPages: [TransactionFeedCacheKey: TransactionFeedPage] = [:]
            var retryForSupersedingRead = false

            for (key, ticket) in zip(orderedKeys, tickets) {
                try Task.checkCancellation()
                let previous = store.transactionFeedPagesByKey[key]
                let limit = max(previous?.nextOffset ?? transactionPageSize, transactionPageSize)
                let loaded = try await loadTransactionFeedPage(
                    database: database,
                    budgetID: budgetID,
                    key: key,
                    limit: limit,
                    offset: 0
                )
                try Task.checkCancellation()
                guard feedRequestIdentity.sessionID == sessionID,
                      store.database === database,
                      store.openedBudgetID == budgetID else {
                    throw CancellationError()
                }
                guard feedRequestIdentity.accepts(ticket) else {
                    retryForSupersedingRead = true
                    break
                }
                refreshedPages[key] = TransactionFeedPage(loaded: loaded)
            }

            if retryForSupersedingRead || !feedRequestIdentity.accepts(tickets) {
                continue
            }
            guard feedRequestIdentity.sessionID == sessionID,
                  store.database === database,
                  store.openedBudgetID == budgetID else {
                throw CancellationError()
            }
            store.transactionFeedPagesByKey.merge(refreshedPages) { _, refreshed in refreshed }
            return
        }
    }

    func transactionFeedCacheKeyOrder(
        _ lhs: TransactionFeedCacheKey,
        _ rhs: TransactionFeedCacheKey
    ) -> Bool {
        let lhsScope = transactionFeedScopeOrder(lhs.scope)
        let rhsScope = transactionFeedScopeOrder(rhs.scope)
        if lhsScope != rhsScope { return lhsScope < rhsScope }
        return lhs.querySignature.stableSortKey < rhs.querySignature.stableSortKey
    }

    func transactionFeedScopeOrder(_ scope: TransactionFeedCacheScope) -> String {
        switch scope {
        case .account(let accountID): "account|\(accountID)"
        case .spending: "spending"
        }
    }

    /// `transactionID` is chosen once per editor presentation so a retried save
    /// is idempotent: when that row already exists (live or tombstoned) the
    /// commit writes nothing and the call succeeds. `nil` mints a fresh id.
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        transactionID callerTransactionID: String? = nil,
        actionSource: BudgetActionSource = .ui,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let draft = try await ScheduleSQL.draftByResolvingSchedule(draft, in: database)
        let transactionID = callerTransactionID ?? UUID().uuidString
        var builder = LocalFirstSyncMessageBuilder()
        let payeeResolution = try await resolvePayeeIfNeeded(
            draft: draft,
            database: database,
            builder: &builder
        )

        let transactionMessages: [ActualSyncDecodedMessage]
        var changedAccounts = [draft.accountID]
        var affectedTransactionIDs = [transactionID]
        var graph: BudgetTransactionGraph = .simple
        if draft.isTransfer {
            guard let payeeID = payeeResolution.payeeID else {
                throw LocalFirstError.invalidLocalWrite("missing payee")
            }
            let transfer = try await TransactionCreationSQL.createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeID,
                builder: &builder,
                in: database
            )
            transactionMessages = transfer.messages
            changedAccounts.append(transfer.destinationAccountID)
            affectedTransactionIDs.append(transfer.pairedTransactionID)
            graph = .transfer(pairedID: transfer.pairedTransactionID)
        } else if draft.isSplit {
            let split = try await SplitFamilySQL.createSplitFamilyWrite(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder,
                in: database
            )
            transactionMessages = split.messages
            changedAccounts.append(contentsOf: split.affectedAccountIDs)
            affectedTransactionIDs = split.affectedTransactionIDs
            let childIDs = split.affectedTransactionIDs.filter { $0 != transactionID }
            graph = .split(childIDs: childIDs)
        } else {
            transactionMessages = try await TransactionCreationSQL.createSimpleTransactionMessages(
                draft,
                transactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder,
                in: database
            )
        }

        let learningIDs: Set<String> = !draft.isTransfer && !draft.isSplit && draft.categoryID != nil
            ? [transactionID]
            : []
        let typedPayeeName = trimmedPayeeName(draft.payeeName)
        let creation: PendingPayeeCreation? = if !payeeResolution.messages.isEmpty,
            let createdID = payeeResolution.payeeID,
            let name = typedPayeeName {
            PendingPayeeCreation(payeeID: createdID, name: name, messages: payeeResolution.messages)
        } else {
            nil
        }
        let finalGraph = graph
        let finalAffectedIDs = affectedTransactionIDs
        let absence = callerTransactionID.map { TransactionCreationSQL.TransactionIDAbsence(transactionID: $0) }
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        let alreadyCommitted = try await database.commitUserActionPlan(source: actionSource) { database, db in
            if let absence, try absence.isViolated(in: database, db: db) {
                return UserActionPlan(drafts: [], descriptor: nil, outcome: true)
            }
            // A payee another writer created with this name since resolution
            // is reused instead of creating a duplicate (5.2b).
            let settled = try PayeeSQL.settlePayeeCreation(
                resolvedPayeeID: payeeResolution.payeeID, creation: creation, in: database, db: db
            )
            let settledTransactionMessages: [ActualSyncDecodedMessage]
            if let built = payeeResolution.payeeID, let final = settled.payeeID {
                settledTransactionMessages = PayeeSQL.retargetingPayee(
                    transactionMessages, from: built, to: final
                )
            } else {
                settledTransactionMessages = transactionMessages
            }
            return UserActionPlan(
                drafts: settled.creationMessages + settledTransactionMessages,
                descriptor: .createTransaction(CreateTransactionDescriptor(
                    month: draft.month.rawValue,
                    amount: draft.amountMinorUnits,
                    payeeName: typedPayeeName,
                    categoryID: draft.categoryID,
                    primaryTransactionID: transactionID,
                    transactionIDs: finalAffectedIDs,
                    graph: finalGraph,
                    createdPayeeID: settled.createdPayeeID
                )),
                learningTransactionIDs: learningIDs,
                outcome: false
            )
        }.outcome
        await didCreate()

        let uniqueAccounts = Array(Set(changedAccounts))
        let tail = await store.finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: uniqueAccounts,
            learningIDs: alreadyCommitted ? [] : learningIDs
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: uniqueAccounts,
                months: [draft.month.rawValue],
                transactions: [transactionID]
            ),
            refreshPending: tail.refreshPending
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        baseline: ActualTransaction? = nil,
        actionSource: BudgetActionSource = .ui,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let draft = try await ScheduleSQL.draftByResolvingSchedule(
            draft,
            existingTransactionID: transactionID,
            in: database
        )
        var builder = LocalFirstSyncMessageBuilder()
        let payeeResolution = try await resolvePayeeIfNeeded(
            draft: draft,
            database: database,
            builder: &builder
        )
        let creation: PendingPayeeCreation? = if !payeeResolution.messages.isEmpty,
            let createdID = payeeResolution.payeeID,
            let name = trimmedPayeeName(draft.payeeName) {
            PendingPayeeCreation(payeeID: createdID, name: name, messages: payeeResolution.messages)
        } else {
            nil
        }
        let typedPayeeName = trimmedPayeeName(draft.payeeName)
        let payeeBuilder = builder
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        // The existing row, its family and the History decision are read inside
        // the write transaction so a remote edit that landed since the editor
        // opened is not judged against stale state.
        let committed = try await database.commitUserActionPlan(
            source: actionSource,
            reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition(
                transactionID: transactionID,
                authorization: reconciliationAuthorization
            )
        ) { database, db in
            var builder = payeeBuilder
            let settled = try PayeeSQL.settlePayeeCreation(
                resolvedPayeeID: payeeResolution.payeeID, creation: creation, in: database, db: db
            )
            let resolvedPayeeID = settled.payeeID
            let createdPayeeID = settled.createdPayeeID
            let existing = try TransactionReadSQL.fetchTransaction(id: transactionID, in: database, db: db)
            let existingState = try TransactionEditSQL.existingTransactionState(
                id: transactionID,
                columns: try TransactionRowColumns.resolve(in: database, db: db),
                in: database,
                db: db
            )
            let update = try TransactionEditSQL.updateTransactionMessages(
                transactionID: transactionID,
                draft: draft,
                payeeID: resolvedPayeeID,
                reconciliationAuthorization: reconciliationAuthorization,
                baseline: baseline,
                builder: &builder,
                in: database,
                db: db
            )
            let descriptor: BudgetActionDescriptor?
            let shouldRecord = existing.map {
                BudgetTransactionLogging.shouldRecordUpdate(
                    existing: $0,
                    draft: draft,
                    resolvedPayeeID: resolvedPayeeID
                )
            } ?? true
            if shouldRecord {
                descriptor = .editTransaction(EditTransactionDescriptor(
                    month: draft.month.rawValue,
                    payeeName: typedPayeeName ?? existing?.payeeName,
                    transactionID: transactionID,
                    affectedIDs: update.affectedTransactionIDs,
                    unsafeGraph: BudgetTransactionLogging.topologyChanged(
                        existing: existingState,
                        draft: draft,
                        primaryID: transactionID,
                        affectedIDs: update.affectedTransactionIDs
                    ),
                    createdPayeeID: createdPayeeID
                ))
            } else if let existing {
                let metadata = BudgetTransactionLogging.metadataChanges(existing: existing, draft: draft)
                descriptor = metadata.notes || metadata.cleared
                    ? .transactionMetadata(TransactionMetadataActionDescriptor(
                        month: draft.month.rawValue,
                        payeeName: typedPayeeName ?? existing.payeeName,
                        notesChanged: metadata.notes,
                        clearedChanged: metadata.cleared
                    ))
                    : nil
            } else {
                descriptor = nil
            }
            // loot-core learns only from an update whose diff carries a category.
            let learningIDs = update.categoryAssignedIDs(among: [transactionID])
            return UserActionPlan(
                drafts: settled.creationMessages + update.messages,
                descriptor: descriptor,
                learningTransactionIDs: learningIDs,
                outcome: (update: update, learningIDs: learningIDs)
            )
        }.outcome
        let update = committed.update
        let learningIDs = committed.learningIDs
        await didUpdate()

        let changedAccounts = Array(Set(update.affectedAccountIDs + [originalAccountID, draft.accountID]))
        let changedMonths = Array(Set([originalMonth, draft.month.rawValue]))
        let tail = await store.finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: changedAccounts,
            learningIDs: learningIDs
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: update.affectedTransactionIDs
            ),
            refreshPending: tail.refreshPending
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization] = [:],
        actionSource: BudgetActionSource = .ui,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionsAndRefresh(
            [transaction],
            categoryID: categoryID,
            budgetID: budgetID,
            reconciliationAuthorizations: reconciliationAuthorizations,
            actionSource: actionSource,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization] = [:],
        actionSource: BudgetActionSource = .ui,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        guard !transactions.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transactions")
        }

        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        var transactionIDs = Set<String>()
        var accountIDs = Set<String>()
        var monthIDs = Set<String>()
        var items: [BudgetCategorizeFact] = []

        for transaction in transactions {
            guard let transactionID = transaction.id,
                  !transactionID.isEmpty,
                  transactionIDs.insert(transactionID).inserted else {
                throw LocalFirstError.invalidLocalWrite("invalid transaction selection")
            }
            guard let monthID = transaction.date.actualYearMonth else {
                throw LocalFirstError.invalidLocalWrite("invalid transaction date")
            }
            accountIDs.insert(transaction.account)
            monthIDs.insert(monthID)
            items.append(BudgetCategorizeFact(
                transactionID: transactionID,
                beforeCategoryID: transaction.category,
                afterCategoryID: categoryID
            ))
        }

        let representativeMonth = monthIDs.sorted().first ?? ""
        let descriptor = BudgetActionDescriptor.categorize(CategorizeTransactionDescriptor(
            month: representativeMonth,
            categoryID: categoryID,
            items: items
        ))
        let orderedIDs = items.map(\.transactionID)
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        _ = try await database.commitUserActionPlan(source: actionSource) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            var messages: [ActualSyncDecodedMessage] = []
            for transactionID in orderedIDs {
                messages += try TransactionEditSQL.categorizeTransactionMessages(
                    transactionID: transactionID,
                    categoryID: categoryID,
                    reconciliationAuthorization: reconciliationAuthorizations[transactionID],
                    builder: &builder,
                    in: database,
                    db: db
                )
            }
            return UserActionPlan(
                drafts: messages,
                descriptor: descriptor,
                learningTransactionIDs: Set(orderedIDs),
                outcome: ()
            )
        }
        await didUpdate()
        let changedAccounts = accountIDs.sorted()
        let changedMonths = monthIDs.sorted()
        let changedTransactions = transactionIDs.sorted()
        let tail = await store.finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: changedAccounts,
            learningIDs: transactionIDs
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: changedTransactions
            ),
            refreshPending: tail.refreshPending
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization? = nil,
        actionSource: BudgetActionSource = .ui,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }

        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let amount = transaction.amount ?? 0
        let payeeName = transaction.payeeName
        let categoryID = transaction.category
        #if DEBUG
        await store.testSeams?.userActionBeforeCommitHook?()
        #endif
        let committed = try await database.commitUserActionPlan(
            source: actionSource,
            reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition(
                transactionID: transactionID,
                authorization: reconciliationAuthorization
            )
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let delete = try TransactionEditSQL.deleteTransactionMessages(
                transactionID: transactionID,
                reconciliationAuthorization: reconciliationAuthorization,
                builder: &builder,
                in: database,
                db: db
            )
            let existingState = try TransactionEditSQL.existingTransactionState(
                id: transactionID,
                columns: try TransactionRowColumns.resolve(in: database, db: db),
                in: database,
                db: db
            )
            let graph: BudgetTransactionGraph
            if existingState.isParent {
                graph = .split(childIDs: existingState.childIDs)
            } else if let pairedID = existingState.transferID {
                graph = .transfer(pairedID: pairedID)
            } else {
                graph = .simple
            }
            return UserActionPlan(
                drafts: delete.messages,
                descriptor: .deleteTransaction(DeleteTransactionDescriptor(
                    month: monthID,
                    amount: amount,
                    payeeName: payeeName,
                    categoryID: categoryID,
                    transactionIDs: delete.affectedTransactionIDs,
                    graph: graph
                )),
                outcome: delete
            )
        }
        let delete = committed.outcome
        await didDelete()

        let changedAccounts = Array(Set(delete.affectedAccountIDs + [transaction.account]))
        let tail = await store.finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: changedAccounts
        )
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: [monthID],
                transactions: delete.affectedTransactionIDs
            ),
            refreshPending: tail.refreshPending
        )
    }

    private func resolvePayeeIfNeeded(
        draft: TransactionDraft,
        database: BudgetDatabase,
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> (payeeID: String?, messages: [ActualSyncDecodedMessage]) {
        let trimmedName = draft.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Actual saves a transaction without a payee; a transfer is the payee, so it needs one.
        if (draft.payeeID ?? "").isEmpty && trimmedName.isEmpty && !draft.isTransfer {
            return (nil, [])
        }
        if let selectedPayeeID = draft.payeeID, !selectedPayeeID.isEmpty {
            try await TransactionCreationSQL.requireLivePayee(selectedPayeeID, in: database)
        }
        let resolved = try await TransactionCreationSQL.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder,
            in: database
        )
        return (resolved.payeeID, resolved.messages)
    }

    private func trimmedPayeeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Wallet import runs the shared import step the way Bank Sync does (upstream
    /// `reconcileTransactions` for a synced account): rules, then
    /// `reconcileProjectedImport` with `.bankSync` options, then
    /// `importReconcileWrites`, in one commit. The match is not strict: a device
    /// gives Wallet transactions its own IDs, so a row stored with another ID
    /// still matches by amount and date and takes the new ID (sync.ts, "account
    /// sync sources can give two different transaction IDs"). Like upstream, an
    /// import never learns categories.
    ///
    /// A concurrent writer can import the same `imported_id`, or change a
    /// matched row, between the read and the commit. Retry once with a fresh
    /// read and plan; a second conflict is reported to the caller.
    func importWalletTransactions(
        _ candidates: [WalletTransactionCandidate],
        intoAccountID accountID: String,
        budgetID: String
    ) async throws -> WalletTransactionImportResult {
        do {
            return try await importWalletTransactionsOnce(
                candidates, intoAccountID: accountID, budgetID: budgetID, attempt: 1
            )
        } catch LocalFirstError.importedTransactionConflict {
            return try await importWalletTransactionsOnce(
                candidates, intoAccountID: accountID, budgetID: budgetID, attempt: 2
            )
        }
    }

    private func importWalletTransactionsOnce(
        _ walletCandidates: [WalletTransactionCandidate],
        intoAccountID accountID: String,
        budgetID: String,
        attempt: Int
    ) async throws -> WalletTransactionImportResult {
        guard !accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let accountIsOffBudget = try await AccountSQL.accountIsOffBudget(accountID, in: database)
        // loot-core resolves `trans.payee` before `runRules`, so Payee-is
        // conditions and the payee match pass see existing non-transfer payees.
        let payeeIDsByName = try await PayeeSQL.fetchPayees(in: database).reduce(
            into: [String: String]()
        ) { result, payee in
            guard payee.transferAccount == nil, let id = payee.id else { return }
            let key = payee.name.lowercased()
            if result[key] == nil {
                result[key] = id
            }
        }
        let candidates = walletCandidates.map {
            WalletTransactionMapper.reconcileCandidate(
                from: $0,
                payeeID: payeeIDsByName[$0.payeeName.lowercased()]
            )
        }
        // Wallet days are local calendar days, so rules read them in the
        // device's zone, as Wallet import always has.
        let previews = try await RulePreviewSQL.previewRules(
            for: candidates.map { ImportReconcileProjection.previewDraft(for: $0, accountID: accountID) },
            dateTimeZone: .autoupdatingCurrent,
            in: database
        )
        guard previews.count == candidates.count else {
            throw LocalFirstError.invalidLocalWrite("missing import rule preview")
        }
        let projection = ImportReconcileProjection.project(
            candidates: candidates,
            previews: previews,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget
        )
        let outcome = try await ImportReconcileSteps.reconcileProjectedImport(
            database: database,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget,
            candidateDayIDs: candidates.map(\.dayID),
            importedIDs: Set(candidates.compactMap(\.financialID)),
            projected: projection.candidates,
            options: .bankSync
        )

        let existingByID = Dictionary(
            outcome.existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let matched = try outcome.matchedUpdates.map { update in
            guard let existing = existingByID[update.existingID] else {
                throw LocalFirstError.invalidLocalWrite("missing matched transaction")
            }
            return (update: update, existing: existing)
        }
        let inserts = outcome.plan.inserts
        let unchangedCount = outcome.plan.entries.reduce(0) { count, entry in
            if case .unchanged = entry { return count + 1 }
            return count
        }
        let matchedCount = matched.count + unchangedCount
        let result = WalletTransactionImportResult(
            addedCount: inserts.count,
            matchedCount: matchedCount,
            skippedCount: walletCandidates.count - inserts.count - matchedCount
        )
        guard !inserts.isEmpty || !matched.isEmpty else {
            return result
        }

        var builder = LocalFirstSyncMessageBuilder()
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000
        let writes = try await ImportReconcileSteps.importReconcileWrites(
            database: database,
            accountID: accountID,
            accountIsOffBudget: accountIsOffBudget,
            updates: matched,
            inserts: inserts,
            options: .bankSync,
            sortOrder: { sortOrderBase + Double($0) },
            builder: &builder
        )
        guard !writes.messages.isEmpty else {
            return result
        }

        #if DEBUG
        await store.testSeams?.walletImportBeforeCommitHook?(attempt)
        #endif
        guard store.database === database, generation == store.budgetSessionGeneration else {
            throw CancellationError()
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            writes.messages,
            expectedAbsentImportedIDs: ImportedIDAbsence(
                accountID: accountID,
                importedIDs: inserts.compactMap(\.financialID)
            ),
            expectedMatchedRows: MatchedRowsUnchanged(
                accountID: accountID,
                reviewed: outcome.reviewedRows
            )
        )

        // A pending refresh invalidates the feed caches; the import itself
        // is complete and not repeatable, so its summary never reports it.
        _ = await store.finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: Array(writes.affectedAccountIDs)
        )
        return result
    }

    func reconciledMutationReview(
        budgetID: String,
        transactionID: String
    ) async throws -> ReconciledTransactionMutationReview? {
        try await ReconciledMutationReviewSQL.reconciledMutationReview(
            transactionID: transactionID,
            in: store.requireDatabase(for: budgetID)
        )
    }

    func unlockReconciledTransactionAndRefresh(
        budgetID: String,
        accountID: String,
        transactionID: String
    ) async throws -> AccountReconciliationMutationResult {
        let database = try store.requireDatabase(for: budgetID)
        let write = try await ReconciliationSQL.unlockReconciledTransaction(
            accountID: accountID,
            transactionID: transactionID,
            now: Date(),
            in: database
        )
        return try await store.reconciliation.finishReconciliationWrite(
            write,
            database: database,
            budgetID: budgetID,
            accountID: accountID
        )
    }

    func fetchTransaction(budgetID: String, id: String) async throws -> ActualTransaction? {
        let database = try store.requireDatabase(for: budgetID)
        return try await TransactionReadSQL.fetchTransaction(id: id, in: database)
    }

    func sharedTransactionLookup(budgetID: String, id: String) async throws -> SharedTransactionLookup {
        let database = try store.requireDatabase(for: budgetID)
        return try await TransactionReadSQL.sharedTransactionLookup(id: id, in: database)
    }

    func cachedCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) -> LoadedAccountTransactions? {
        store.categoryTransactionsByKey[categoryTransactionKey(budgetID, categoryID, month)]?.loaded
    }

    func cachedUncategorizedTransactions(
        budgetID: String,
        month: String
    ) -> LoadedUncategorizedTransactions? {
        store.uncategorizedTransactionsByKey[uncategorizedTransactionKey(budgetID, month)]
    }

    func refreshCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let revision = store.cachePublicationRevision
        let maps = try await TransactionReadSQL.nameMaps(database)
        let transactions = try await TransactionReadSQL.fetchTransactions(in: database)
        #if DEBUG
        await store.testSeams?.readPublicationHook?(.categoryFeed)
        #endif
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        // A write reload since this read began already published fresher rows.
        guard revision == store.cachePublicationRevision else { return }
        publishCategoryTransactions(
            budgetID: budgetID, categoryID: categoryID, month: month,
            allTransactions: transactions, maps: maps
        )
    }

    /// Filters an already-fetched transaction table into one category feed, so a
    /// reload can serve every cached feed from a single read.
    func publishCategoryTransactions(
        budgetID: String,
        categoryID: String,
        month: String,
        allTransactions: [ActualTransaction],
        maps: TransactionReadSQL.NameMaps
    ) {
        let transactions = allTransactions.filter { transaction in
            transaction.belongs(toCategory: categoryID, month: month)
        }
        store.categoryTransactionsByKey[categoryTransactionKey(budgetID, categoryID, month)] = TransactionFeedPage(
            loaded: LoadedAccountTransactions(
                transactions: transactions,
                balance: nil,
                accountNames: maps.accountNames,
                categoryNames: maps.categoryNames,
                payeeNames: maps.payeeNames,
                transferPayeeIDs: maps.transferPayeeIDs,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs,
                reachedEnd: true
            )
        )
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        let database = try store.requireDatabase(for: budgetID)
        let monthGraph = try await BudgetMonthSQL.fetchBudgetMonth(month: month, in: database)
        return TransactionEditorOptions(
            accounts: try await AccountSQL.fetchAccounts(in: database).filter { !$0.closed },
            categories: editorVisibleCategories(from: monthGraph),
            categoryGroups: monthGraph.editorCategoryGroups(currency: store.budgetCurrency(budgetID: budgetID)),
            payees: try await PayeeSQL.fetchPayees(in: database)
        )
    }

    func editorVisibleCategories(from month: BudgetMonth) -> [ActualCategory] {
        month.categoryGroups.flatMap { group in
            BudgetCategoryVisibility.visibleCategories(in: group).compactMap { category in
                ActualCategory(
                    id: category.id,
                    name: category.name,
                    isIncome: category.isIncome,
                    hidden: category.hidden,
                    groupID: category.groupID
                )
            }
        }
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let revision = store.cachePublicationRevision
        let maps = try await TransactionReadSQL.nameMaps(database)
        let rows = try await TransactionReadSQL.fetchUncategorizedTransactions(in: database)
        #if DEBUG
        await store.testSeams?.readPublicationHook?(.uncategorizedFeed)
        #endif
        return try await publishUncategorizedTransactions(
            database: database, budgetID: budgetID, month: month,
            generation: generation, revision: revision, rows: rows, maps: maps
        )
    }

    /// Filters already-fetched uncategorized candidates for one cached month key.
    func publishUncategorizedTransactions(
        database: BudgetDatabase,
        budgetID: String,
        month: String,
        generation: Int,
        revision: Int,
        rows: [ActualTransaction],
        maps: TransactionReadSQL.NameMaps
    ) async throws -> LoadedUncategorizedTransactions {
        let transactions = rows.filter { transaction in
            Self.isUncategorized(
                transaction,
                transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
                offBudgetAccountIDs: maps.offBudgetAccountIDs
            )
        }
        let categoryGroups = try await editorCategoryGroups(database: database, month: month, budgetID: budgetID)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        let loaded = LoadedUncategorizedTransactions(
            transactions: transactions,
            accountNames: maps.accountNames,
            categoryNames: maps.categoryNames,
            payeeNames: maps.payeeNames,
            transferPayeeIDs: maps.transferPayeeIDs,
            transferAccountIDsByPayeeID: maps.transferAccountIDsByPayeeID,
            offBudgetAccountIDs: maps.offBudgetAccountIDs,
            categoryGroups: categoryGroups
        )
        if revision == store.cachePublicationRevision {
            store.uncategorizedTransactionsByKey[uncategorizedTransactionKey(budgetID, month)] = loaded
        }
        return loaded
    }

    // Cross-budget transfers from a budget account still need a category.
    // Split parents are excluded because their effective category is always
    // null; uncategorized children are independent `.inline` rows.
    // Uncategorized is budget-global: prior months still reduce To Budget,
    // and Actual web's banner has no month filter.
    static func isUncategorized(
        _ transaction: ActualTransaction,
        transferAccountIDsByPayeeID: [String: String],
        offBudgetAccountIDs: Set<String>
    ) -> Bool {
        let destinationAccountID = transaction.payee.flatMap { transferAccountIDsByPayeeID[$0] }
        let isOnBudgetTransfer = destinationAccountID.map { !offBudgetAccountIDs.contains($0) } ?? false
        return !offBudgetAccountIDs.contains(transaction.account)
            && (transaction.category?.isEmpty ?? true)
            && transaction.subtransactions.isEmpty
            && !transaction.isParent
            && !isOnBudgetTransfer
    }

    func editorCategoryGroups(
        database: BudgetDatabase,
        month: String,
        budgetID: String
    ) async throws -> [TransactionEditorCategoryGroup] {
        let budgetMonth = try await BudgetMonthSQL.fetchBudgetMonth(month: month, in: database)
        return budgetMonth.editorCategoryGroups(currency: store.budgetCurrency(budgetID: budgetID))
    }

    func categoryTransactionKey(_ budgetID: String, _ categoryID: String, _ month: String) -> String {
        "\(budgetID)|\(categoryID)|\(month)"
    }

    func uncategorizedTransactionKey(_ budgetID: String, _ month: String) -> String {
        "\(budgetID)|\(month)"
    }

    /// Actual's running-balance preferences (`RunningBalancePreference`), so
    /// the setting follows the budget to both web layouts. The current column
    /// layout is read inside the commit. Last write wins; History records nothing.
    func setShowsRunningBalance(budgetID: String, accountID: String, enabled: Bool) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let written = try await database.commitSyncedPreferences(
            reading: RunningBalancePreference.keys(accountID: accountID)
        ) { stored in
            RunningBalancePreference.writes(
                enabled: enabled,
                accountID: accountID,
                current: RunningBalancePreference.values(stored, accountID: accountID)
            )
        }
        guard written else { return }
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        }
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        let database = try store.requireDatabase(for: budgetID)
        return try await RulePreviewSQL.previewRules(for: draft, in: database)
    }
}

extension TransactionWorkflows: TransactionRepositoryProtocol { }
