import Foundation

extension LocalFirstActualStore {
    func existingImportedIDs(budgetID: String, accountID: String) async throws -> Set<String> {
        let database = try requireDatabase(for: budgetID)
        return try await database.existingImportedIDs(accountID: accountID)
    }

    func importWalletTransactions(
        _ candidates: [WalletTransactionCandidate],
        intoAccountID accountID: String,
        budgetID: String
    ) async throws -> WalletTransactionImportResult {
        guard !accountID.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing account")
        }

        let database = try requireDatabase(for: budgetID)
        var seenIDs = try await database.existingImportedIDs(accountID: accountID)
        var importedCount = 0
        var duplicateCount = 0
        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        var categorizedIDs = Set<String>()
        var monthIDs = Set<String>()
        var resolvedPayeeIDs: [String: String] = [:]
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000

        for (index, candidate) in candidates.enumerated() {
            if seenIDs.contains(candidate.financialID) {
                duplicateCount += 1
                continue
            }

            var draft = WalletTransactionMapper.draft(
                from: candidate,
                accountID: accountID,
                sortOrder: sortOrderBase + Double(index)
            )
            let preview = try await database.previewRules(for: draft)
            if preview.deletesTransaction {
                continue
            }
            draft = WalletTransactionMapper.applyingImportPreview(draft, preview)

            let payeeResolution = try await resolveImportPayee(
                draft: draft,
                resolvedPayeeIDs: &resolvedPayeeIDs,
                database: database,
                builder: &builder
            )
            let transactionID = UUID().uuidString
            let transactionMessages: [ActualSyncDecodedMessage]
            if draft.isSplit {
                transactionMessages = try await database.createSplitTransactionMessages(
                    draft: draft,
                    parentTransactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
            } else {
                transactionMessages = try await database.createSimpleTransactionMessages(
                    draft,
                    transactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
            }

            messages.append(contentsOf: payeeResolution.messages)
            messages.append(contentsOf: transactionMessages)
            seenIDs.insert(candidate.financialID)
            importedCount += 1
            monthIDs.insert(draft.month.rawValue)
            if draft.categoryID != nil {
                categorizedIDs.insert(transactionID)
            }
        }

        guard !messages.isEmpty else {
            return WalletTransactionImportResult(
                importedCount: importedCount,
                duplicateCount: duplicateCount
            )
        }

        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        let learningMessages = try await database.categoryLearningRuleMessages(
            changedTransactionIDs: categorizedIDs,
            builder: &builder
        )
        if !learningMessages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(learningMessages)
            rulesByBudget[budgetID] = try await database.fetchRules()
            payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
                .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        }

        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: budgetID,
            accountIDs: [accountID],
            monthIDs: Array(monthIDs)
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        return WalletTransactionImportResult(
            importedCount: importedCount,
            duplicateCount: duplicateCount
        )
    }

    private func resolveImportPayee(
        draft: TransactionDraft,
        resolvedPayeeIDs: inout [String: String],
        database: BudgetDatabase,
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> (payeeID: String, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID = draft.payeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }

        let key = draft.payeeName.lowercased()
        if let cachedID = resolvedPayeeIDs[key] {
            return (cachedID, [])
        }

        let resolution = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: nil,
            payeeName: draft.payeeName,
            builder: &builder
        )
        resolvedPayeeIDs[key] = resolution.payeeID
        return resolution
    }
}
