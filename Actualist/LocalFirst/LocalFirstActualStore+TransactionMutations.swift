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
        let database = try requireDatabase(for: budgetID)
        let draft = try await database.draftByResolvingSchedule(draft)
        let transactionID = UUID().uuidString
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

        let messages = payeeResolution.messages + transactionMessages
        let learningIDs: Set<String> = !draft.isTransfer && !draft.isSplit && draft.categoryID != nil
            ? [transactionID]
            : []
        let createdPayeeID = payeeResolution.messages.isEmpty ? nil : payeeResolution.payeeID
        _ = try await database.commitUserAction(
            messages,
            descriptor: .createTransaction(CreateTransactionDescriptor(
                month: draft.month.rawValue,
                amount: draft.amountMinorUnits,
                payeeName: trimmedPayeeName(draft.payeeName),
                categoryID: draft.categoryID,
                primaryTransactionID: transactionID,
                transactionIDs: affectedTransactionIDs,
                graph: graph,
                createdPayeeID: createdPayeeID
            )),
            source: actionSource,
            learningTransactionIDs: learningIDs
        )
        try await reloadRulesIfNeeded(learningIDs: learningIDs, database: database, budgetID: budgetID)
        await didCreate()

        let uniqueAccounts = Array(Set(changedAccounts))
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: uniqueAccounts,
            monthIDs: [draft.month.rawValue]
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: uniqueAccounts,
                months: [draft.month.rawValue],
                transactions: [transactionID]
            )
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            reconciliationAuthorization: reconciliationAuthorization,
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
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
            reconciliationAuthorization: nil,
            actionSource: actionSource,
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
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try requireDatabase(for: budgetID)
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
        let payeeMessages = payeeResolution.messages
        let resolvedPayeeID = payeeResolution.payeeID
        let createdPayeeID = payeeMessages.isEmpty ? nil : resolvedPayeeID
        let typedPayeeName = trimmedPayeeName(draft.payeeName)
        let learningIDs: Set<String> = draft.categoryID == nil ? [] : [transactionID]
        let payeeBuilder = builder
        await userActionBeforeCommitHook?()
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
                drafts: payeeMessages + update.messages,
                descriptor: descriptor,
                learningTransactionIDs: learningIDs,
                outcome: update
            )
        }.outcome
        try await reloadRulesIfNeeded(learningIDs: learningIDs, database: database, budgetID: budgetID)
        await didUpdate()

        let changedAccounts = Array(Set(update.affectedAccountIDs + [originalAccountID, draft.accountID]))
        let changedMonths = Array(Set([originalMonth, draft.month.rawValue]))
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: changedMonths
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: update.affectedTransactionIDs
            )
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionAndRefresh(
            transaction,
            categoryID: categoryID,
            budgetID: budgetID,
            actionSource: .ui,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionsAndRefresh(
            [transaction],
            categoryID: categoryID,
            budgetID: budgetID,
            actionSource: actionSource,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        try await categorizeTransactionsAndRefresh(
            transactions,
            categoryID: categoryID,
            budgetID: budgetID,
            actionSource: .ui,
            didUpdate: didUpdate
        )
    }

    func categorizeTransactionsAndRefresh(
        _ transactions: [ActualTransaction],
        categoryID: String,
        budgetID: String,
        actionSource: BudgetActionSource,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> TransactionMutationResult {
        guard !transactions.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transactions")
        }

        let database = try requireDatabase(for: budgetID)
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
        await userActionBeforeCommitHook?()
        _ = try await database.commitUserActionPlan(source: actionSource) { database, db in
            var builder = LocalFirstSyncMessageBuilder()
            var messages: [ActualSyncDecodedMessage] = []
            for transactionID in orderedIDs {
                messages += try database.categorizeTransactionMessages(
                    transactionID: transactionID,
                    categoryID: categoryID,
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
        try await reloadRulesIfNeeded(learningIDs: transactionIDs, database: database, budgetID: budgetID)
        await didUpdate()
        let changedAccounts = accountIDs.sorted()
        let changedMonths = monthIDs.sorted()
        let changedTransactions = transactionIDs.sorted()
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: changedMonths
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: changedMonths,
                transactions: changedTransactions
            )
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
        let amount = transaction.amount ?? 0
        let payeeName = transaction.payeeName
        let categoryID = transaction.category
        await userActionBeforeCommitHook?()
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
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: changedAccounts,
            monthIDs: [monthID]
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: changedAccounts,
                months: [monthID],
                transactions: delete.affectedTransactionIDs
            )
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

    private func reloadRulesIfNeeded(
        learningIDs: Set<String>,
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        guard !learningIDs.isEmpty else { return }
        try await refreshRulesCache(database: database, budgetID: budgetID)
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
    }

    private func trimmedPayeeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
