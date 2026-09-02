import Foundation

/// Create / update / delete / categorize gestures. Extracted from
/// `LocalFirstActualStore+Mutations` so History recording does not push that
/// file over the 800-line reassessment line. Wallet and Bank Sync keep their
/// own unrecorded write paths (Q4).
extension LocalFirstActualStore {
    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
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
        didCreate: @escaping () async -> Void
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
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        try await updateTransactionAndRefresh(
            transactionID,
            with: draft,
            budgetID: budgetID,
            originalAccountID: originalAccountID,
            originalMonth: originalMonth,
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
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        let database = try requireDatabase(for: budgetID)
        let existing = try await database.fetchTransaction(id: transactionID)
        let existingState = try await database.existingTransactionState(id: transactionID)
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
        let update = try await database.updateTransactionMessages(
            transactionID: transactionID,
            draft: draft,
            payeeID: payeeResolution.payeeID,
            builder: &builder
        )

        let messages = payeeResolution.messages + update.messages
        let learningIDs: Set<String> = draft.categoryID == nil ? [] : [transactionID]
        let shouldRecord = existing.map {
            BudgetTransactionLogging.shouldRecordUpdate(
                existing: $0,
                draft: draft,
                resolvedPayeeID: payeeResolution.payeeID
            )
        } ?? true
        if shouldRecord {
            let createdPayeeID = payeeResolution.messages.isEmpty ? nil : payeeResolution.payeeID
            let unsafeGraph = BudgetTransactionLogging.topologyChanged(
                existing: existingState,
                draft: draft,
                primaryID: transactionID,
                affectedIDs: update.affectedTransactionIDs
            )
            _ = try await database.commitUserAction(
                messages,
                descriptor: .editTransaction(EditTransactionDescriptor(
                    month: draft.month.rawValue,
                    payeeName: trimmedPayeeName(draft.payeeName) ?? existing?.payeeName,
                    transactionID: transactionID,
                    affectedIDs: update.affectedTransactionIDs,
                    unsafeGraph: unsafeGraph,
                    createdPayeeID: createdPayeeID
                )),
                source: actionSource,
                learningTransactionIDs: learningIDs
            )
        } else if let existing {
            let metadata = BudgetTransactionLogging.metadataChanges(existing: existing, draft: draft)
            if metadata.notes || metadata.cleared {
                _ = try await database.commitUserAction(
                    messages,
                    descriptor: .transactionMetadata(TransactionMetadataActionDescriptor(
                        month: draft.month.rawValue,
                        payeeName: trimmedPayeeName(draft.payeeName) ?? existing.payeeName,
                        notesChanged: metadata.notes,
                        clearedChanged: metadata.cleared
                    )),
                    source: actionSource,
                    learningTransactionIDs: learningIDs
                )
            } else {
                _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
            }
        } else {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        }
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
        didUpdate: @escaping () async -> Void
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
        didUpdate: @escaping () async -> Void
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
        didUpdate: @escaping () async -> Void
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
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard !transactions.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transactions")
        }

        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
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
            messages += try await database.categorizeTransactionMessages(
                transactionID: transactionID,
                categoryID: categoryID,
                builder: &builder
            )
            accountIDs.insert(transaction.account)
            monthIDs.insert(monthID)
            items.append(BudgetCategorizeFact(
                transactionID: transactionID,
                beforeCategoryID: transaction.category,
                afterCategoryID: categoryID
            ))
        }

        let representativeMonth = monthIDs.sorted().first ?? ""
        _ = try await database.commitUserAction(
            messages,
            descriptor: .categorize(CategorizeTransactionDescriptor(
                month: representativeMonth,
                categoryID: categoryID,
                items: items
            )),
            source: actionSource,
            learningTransactionIDs: transactionIDs
        )
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
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        try await deleteTransactionAndRefresh(
            transaction,
            budgetID: budgetID,
            actionSource: .ui,
            didDelete: didDelete
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        actionSource: BudgetActionSource,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        guard let transactionID = transaction.id, !transactionID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        guard let monthID = transaction.date.actualYearMonth else {
            throw LocalFirstError.invalidLocalWrite("invalid transaction date")
        }

        let database = try requireDatabase(for: budgetID)
        let existingState = try await database.existingTransactionState(id: transactionID)
        var builder = LocalFirstSyncMessageBuilder()
        let delete = try await database.deleteTransactionMessages(
            transactionID: transactionID,
            builder: &builder
        )

        let graph: BudgetTransactionGraph
        if existingState.isParent {
            graph = .split(childIDs: existingState.childIDs)
        } else if let pairedID = existingState.transferID {
            graph = .transfer(pairedID: pairedID)
        } else {
            graph = .simple
        }
        _ = try await database.commitUserAction(
            delete.messages,
            descriptor: .deleteTransaction(DeleteTransactionDescriptor(
                month: monthID,
                amount: transaction.amount ?? 0,
                payeeName: transaction.payeeName,
                categoryID: transaction.category,
                transactionIDs: delete.affectedTransactionIDs,
                graph: graph
            )),
            source: actionSource
        )
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
        rulesByBudget[budgetID] = try await database.fetchRules()
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
    }

    private func trimmedPayeeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
