import Foundation

/// Create / update / delete / categorize gestures. Extracted from
/// `LocalFirstActualStore+Mutations` so History recording does not push that
/// file over the 800-line reassessment line. Wallet and Bank Sync keep their
/// own unrecorded write paths (Q4).
extension LocalFirstActualStore {
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await createTransactionAndRefresh(
            draft,
            budgetID: budgetID,
            transactionID: nil,
            actionSource: .ui,
            didCreate: didCreate
        )
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        transactionID: String?,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await createTransactionAndRefresh(
            draft,
            budgetID: budgetID,
            transactionID: transactionID,
            actionSource: .ui,
            didCreate: didCreate
        )
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        actionSource: BudgetActionSource,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await createTransactionAndRefresh(
            draft,
            budgetID: budgetID,
            transactionID: nil,
            actionSource: actionSource,
            didCreate: didCreate
        )
    }

    /// `transactionID` is chosen once per editor presentation so a retried save
    /// is idempotent: when that row already exists (live or tombstoned) the
    /// commit writes nothing and the call succeeds. `nil` mints a fresh id.
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        transactionID callerTransactionID: String?,
        actionSource: BudgetActionSource,
        didCreate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let draft = try await database.draftByResolvingSchedule(draft)
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
            let transfer = try await database.createTransferTransactionMessages(
                draft: draft,
                sourceTransactionID: transactionID,
                payeeID: payeeID,
                builder: &builder
            )
            transactionMessages = transfer.messages
            changedAccounts.append(transfer.destinationAccountID)
            affectedTransactionIDs.append(transfer.pairedTransactionID)
            graph = .transfer(pairedID: transfer.pairedTransactionID)
        } else if draft.isSplit {
            let split = try await database.createSplitFamilyWrite(
                draft: draft,
                parentTransactionID: transactionID,
                payeeID: payeeResolution.payeeID,
                builder: &builder
            )
            transactionMessages = split.messages
            changedAccounts.append(contentsOf: split.affectedAccountIDs)
            affectedTransactionIDs = split.affectedTransactionIDs
            let childIDs = split.affectedTransactionIDs.filter { $0 != transactionID }
            graph = .split(childIDs: childIDs)
        } else {
            guard let payeeID = payeeResolution.payeeID else {
                throw LocalFirstError.invalidLocalWrite("missing payee")
            }
            transactionMessages = try await database.createSimpleTransactionMessages(
                draft,
                transactionID: transactionID,
                payeeID: payeeID,
                builder: &builder
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
        let absence = callerTransactionID.map { BudgetDatabase.TransactionIDAbsence(transactionID: $0) }
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        let alreadyCommitted = try await database.commitUserActionPlan(source: actionSource) { database, db in
            if let absence, try absence.isViolated(in: database, db: db) {
                return UserActionPlan(drafts: [], descriptor: nil, outcome: true)
            }
            // A payee another writer created with this name since resolution
            // is reused instead of creating a duplicate (5.2b).
            let settled = try database.settlePayeeCreation(
                resolvedPayeeID: payeeResolution.payeeID, creation: creation, db: db
            )
            let settledTransactionMessages: [ActualSyncDecodedMessage]
            if let built = payeeResolution.payeeID, let final = settled.payeeID {
                settledTransactionMessages = BudgetDatabase.retargetingPayee(
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
        let tail = await finishDurableTransactionWrite(
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            reconciliationAuthorization: nil,
            actionSource: .ui,
            didUpdate: didUpdate
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        baseline: ActualTransaction? = nil,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            reconciliationAuthorization: reconciliationAuthorization,
            baseline: baseline,
            actionSource: .ui,
            didUpdate: didUpdate
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
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let draft = try await database.draftByResolvingSchedule(
            draft,
            existingTransactionID: transactionID
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
        let learningIDs: Set<String> = draft.categoryID == nil ? [] : [transactionID]
        let payeeBuilder = builder
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        // The existing row, its family and the History decision are read inside
        // the write transaction so a remote edit that landed since the editor
        // opened is not judged against stale state.
        let update = try await database.commitUserActionPlan(
            source: actionSource,
            reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition(
                transactionID: transactionID,
                authorization: reconciliationAuthorization
            )
        ) { database, db in
            var builder = payeeBuilder
            let settled = try database.settlePayeeCreation(
                resolvedPayeeID: payeeResolution.payeeID, creation: creation, db: db
            )
            let resolvedPayeeID = settled.payeeID
            let createdPayeeID = settled.createdPayeeID
            let existing = try database.fetchTransaction(id: transactionID, db: db)
            let existingState = try database.existingTransactionState(
                id: transactionID,
                columns: try database.resolveTransactionRowColumns(db: db),
                db: db
            )
            let update = try database.updateTransactionMessages(
                transactionID: transactionID,
                draft: draft,
                payeeID: resolvedPayeeID,
                reconciliationAuthorization: reconciliationAuthorization,
                baseline: baseline,
                db: db,
                builder: &builder
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
            return UserActionPlan(
                drafts: settled.creationMessages + update.messages,
                descriptor: descriptor,
                learningTransactionIDs: learningIDs,
                outcome: update
            )
        }.outcome
        await didUpdate()

        let changedAccounts = Array(Set(update.affectedAccountIDs + [originalAccountID, draft.accountID]))
        let changedMonths = Array(Set([originalMonth, draft.month.rawValue]))
        let tail = await finishDurableTransactionWrite(
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionAndRefresh(
            transaction,
            categoryID: categoryID,
            budgetID: budgetID,
            reconciliationAuthorizations: reconciliationAuthorizations,
            actionSource: .ui,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization] = [:],
        actionSource: BudgetActionSource,
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionsAndRefresh(
            transactions,
            categoryID: categoryID,
            budgetID: budgetID,
            reconciliationAuthorizations: reconciliationAuthorizations,
            actionSource: .ui,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        reconciliationAuthorizations: [String: ReconciledTransactionMutationAuthorization] = [:],
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        guard !transactions.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transactions")
        }

        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
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
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        _ = try await database.commitUserActionPlan(source: actionSource) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            var messages: [ActualSyncDecodedMessage] = []
            for transactionID in orderedIDs {
                messages += try database.categorizeTransactionMessages(
                    transactionID: transactionID,
                    categoryID: categoryID,
                    reconciliationAuthorization: reconciliationAuthorizations[transactionID],
                    db: db,
                    builder: &builder
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
        let tail = await finishDurableTransactionWrite(
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
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            reconciliationAuthorization: nil,
            actionSource: .ui,
            didDelete: didDelete
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            reconciliationAuthorization: reconciliationAuthorization,
            actionSource: .ui,
            didDelete: didDelete
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        actionSource: BudgetActionSource,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            reconciliationAuthorization: nil,
            actionSource: actionSource,
            didDelete: didDelete
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        reconciliationAuthorization: ReconciledTransactionMutationAuthorization?,
        actionSource: BudgetActionSource,
        didDelete: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }

        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let amount = transaction.amount ?? 0
        let payeeName = transaction.payeeName
        let categoryID = transaction.category
        #if DEBUG
        await testSeams?.userActionBeforeCommitHook?()
        #endif
        let committed = try await database.commitUserActionPlan(
            source: actionSource,
            reconciledMutationPrecondition: ReconciledTransactionMutationPrecondition(
                transactionID: transactionID,
                authorization: reconciliationAuthorization
            )
        ) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            let delete = try database.deleteTransactionMessages(
                transactionID: transactionID,
                reconciliationAuthorization: reconciliationAuthorization,
                db: db,
                builder: &builder
            )
            let existingState = try database.existingTransactionState(
                id: transactionID,
                columns: try database.resolveTransactionRowColumns(db: db),
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
        let tail = await finishDurableTransactionWrite(
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
        if draft.payeeID == nil && trimmedName.isEmpty && (draft.isSplit || draft.isParent) {
            return (nil, [])
        }
        if let selectedPayeeID = draft.payeeID, !selectedPayeeID.isEmpty {
            try await database.requireLivePayee(selectedPayeeID)
        }
        let resolved = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: draft.payeeID,
            payeeName: draft.payeeName,
            builder: &builder
        )
        return (resolved.payeeID, resolved.messages)
    }

    private func trimmedPayeeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
