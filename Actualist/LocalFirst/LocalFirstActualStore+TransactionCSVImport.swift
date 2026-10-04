import Foundation

/// CSV import prepare/apply. Prepare is read-only: parse, all-or-nothing
/// validation, and reconcile matching for review. Apply receives
/// already-decided rows and reuses the shared local-first transaction
/// construction (`createSimpleTransactionMessages` /
/// `createTransferTransactionMessages`, `commitLocalSyncMessagesAndEnqueue`)
/// in one atomic commit — no second transaction-write engine, and no wallet or
/// bank-sync routing.
extension LocalFirstActualStore: TransactionCSVImportRepositoryProtocol {
    func prepareTransactionCSVImport(
        _ request: TransactionCSVImportPreparationRequest
    ) async throws -> TransactionCSVImportReview {
        try Task.checkCancellation()
        let database = try requireDatabase(for: request.budgetID)
        let sessionID = transactionFeedRequestIdentity.sessionID
        let generation = budgetSessionGeneration

        let rows = try await TransactionCSVImportPipeline.rows(
            from: request.data,
            options: request.options
        )

        let payees = try await database.fetchPayees(orderedForPicker: false)
        let categories = try await database.fetchCategories()
        let candidates = try await database.fetchTransactionCSVImportCandidates(accountID: request.accountID)

        guard transactionFeedRequestIdentity.sessionID == sessionID,
              generation == budgetSessionGeneration,
              self.database === database,
              openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        let context = TransactionCSVImportMatchContext(
            payeeIDByName: Self.payeeIDByName(payees),
            transferPayeeIDs: Self.transferPayeeIDs(payees),
            categoryIDByName: Self.categoryIDByName(categories)
        )
        let dispositions = await TransactionCSVImportPipeline.match(
            rows: rows,
            candidates: candidates,
            context: context
        )
        // The match ran off the main actor; reject a review whose session
        // ended meanwhile.
        guard generation == budgetSessionGeneration,
              self.database === database,
              openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        return TransactionCSVImportReview(
            rows: zip(rows, dispositions).map {
                TransactionCSVImportReviewRow(row: $0, disposition: $1)
            },
            sessionGeneration: generation
        )
    }

    func applyTransactionCSVImport(
        _ request: TransactionCSVImportApplyRequest
    ) async throws -> TransactionCSVImportApplyResult {
        try Task.checkCancellation()
        let database = try requireDatabase(for: request.budgetID)
        try requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )
        let payees = try await database.fetchPayees(orderedForPicker: false)
        let categories = try await database.fetchCategories()
        try requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )
        let payeeIDByName = Self.payeeIDByName(payees)
        let transferPayeeIDs = Self.transferPayeeIDs(payees)
        let categoryIDByName = Self.categoryIDByName(categories)

        let accountIsOffBudget = try await database.accountIsOffBudget(request.accountID)

        var builder = LocalFirstSyncMessageBuilder()
        var messages: [ActualSyncDecodedMessage] = []
        var updates: [BudgetDatabase.TransactionCSVImportUpdate] = []
        var affectedAccountIDs: Set<String> = [request.accountID]
        var monthIDs = Set<String>()
        var resolvedPayeeIDs: [String: String] = [:]
        var insertedCount = 0
        var updatedCount = 0
        // Pinned Actual stamps inserted rows with a descending sort_order from
        // Date.now() so file order survives on display.
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000

        // Insert messages are only accumulated here; update messages are built
        // and validated against live rows inside the single commit below, so
        // any throw before or during it leaves zero rows applied.
        for (index, reviewRow) in request.rows.enumerated() {
            let row = reviewRow.row
            switch reviewRow.disposition {
            case .ignored, .skippedReconciled:
                continue
            case .update(let plan):
                updates.append(BudgetDatabase.TransactionCSVImportUpdate(line: row.sourceLine, plan: plan))
                updatedCount += 1
                monthIDs.insert(String(row.dateText.prefix(7)))
            case .insert:
                // Empty payee text resolves to a null payee, never an
                // unnamed payee.
                let trimmedPayee = row.payeeName
                let payeeID: String?
                if trimmedPayee.isEmpty {
                    payeeID = nil
                } else if let cached = resolvedPayeeIDs[trimmedPayee.lowercased()] {
                    payeeID = cached
                } else if let existing = payeeIDByName[trimmedPayee.lowercased()] {
                    payeeID = existing
                } else {
                    let resolution = try await database.resolveOrCreatePayeeMessages(
                        selectedPayeeID: nil,
                        payeeName: trimmedPayee,
                        builder: &builder
                    )
                    resolvedPayeeIDs[trimmedPayee.lowercased()] = resolution.payeeID
                    payeeID = resolution.payeeID
                    // The payee/payee_mapping creation messages must join the
                    // same atomic commit or the transaction's payee join
                    // resolves to nothing on read-back.
                    messages += resolution.messages
                }

                // Write-time payee state is authoritative for the transfer
                // shape (the wallet-import path derives it the same way);
                // the reviewed flag is display-only.
                let isTransfer = payeeID.map(transferPayeeIDs.contains) ?? false
                var draft = TransactionDraft(
                    accountID: request.accountID,
                    date: row.date,
                    amountMinorUnits: row.amountMinorUnits,
                    payeeID: payeeID,
                    payeeName: trimmedPayee,
                    // Actual strips the category from every off-budget insert.
                    categoryID: accountIsOffBudget
                        ? nil
                        : row.categoryName.flatMap { categoryIDByName[$0.lowercased()] },
                    notes: row.notes,
                    // The import handler's traced default when the row lacks
                    // a cleared value.
                    cleared: row.cleared ?? true,
                    isTransfer: isTransfer
                )
                draft.importedPayee = trimmedPayee.isEmpty ? nil : trimmedPayee
                draft.importedID = row.importedID
                draft.sortOrder = sortOrderBase - Double(index)

                let transactionID = UUID().uuidString
                if isTransfer {
                    guard let payeeID else {
                        throw LocalFirstError.invalidLocalWrite("missing payee")
                    }
                    let transfer = try await database.createTransferTransactionMessages(
                        draft: draft,
                        sourceTransactionID: transactionID,
                        payeeID: payeeID,
                        builder: &builder
                    )
                    messages += transfer.messages
                    affectedAccountIDs.insert(transfer.destinationAccountID)
                } else {
                    messages += try await database.createSimpleTransactionMessages(
                        draft,
                        transactionID: transactionID,
                        payeeID: payeeID,
                        builder: &builder
                    )
                }
                insertedCount += 1
                monthIDs.insert(String(row.dateText.prefix(7)))
            }
        }

        guard !messages.isEmpty || !updates.isEmpty else {
            return TransactionCSVImportApplyResult(insertedCount: 0, updatedCount: 0)
        }
        // Known duplication: the commit tail below (reload, flush) is copied
        // from the other store write methods until the shared tail exists.
        try requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )
        try await database.commitTransactionCSVImport(
            accountID: request.accountID,
            updates: updates,
            insertMessages: messages,
            builder: &builder
        )
        try await reloadAfterTransactionMutation(
            database: database,
            budgetID: request.budgetID,
            accountIDs: Array(affectedAccountIDs),
            monthIDs: Array(monthIDs)
        )
        await schedulePendingLocalMessageFlush(database: database, budgetID: request.budgetID)
        return TransactionCSVImportApplyResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount
        )
    }

    private static func payeeIDByName(_ payees: [ActualPayee]) -> [String: String] {
        var result: [String: String] = [:]
        for payee in payees {
            guard let id = payee.id, !id.isEmpty else { continue }
            let key = payee.name.lowercased()
            if result[key] == nil {
                result[key] = id
            }
        }
        return result
    }

    private static func transferPayeeIDs(_ payees: [ActualPayee]) -> Set<String> {
        Set(payees.compactMap { payee in
            guard let id = payee.id, payee.transferAccount?.isEmpty == false else { return nil }
            return id
        })
    }

    private static func categoryIDByName(_ categories: [ActualCategory]) -> [String: String] {
        var result: [String: String] = [:]
        for category in categories {
            guard let id = category.id, !id.isEmpty else { continue }
            let key = category.name.lowercased()
            if result[key] == nil {
                result[key] = id
            }
        }
        return result
    }
}
