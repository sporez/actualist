import Foundation

/// CSV import prepare/apply. Prepare is read-only: parse, all-or-nothing
/// validation, then the shared import reconcile (rules, matching) for review.
/// Apply receives the decided rows and writes them through the same shared step
/// as Bank Sync (`importReconcileWrites`) in one atomic commit, with the
/// review's preconditions re-checked inside it. There is no second
/// reconcile implementation and no wallet or bank-sync routing.
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
        let accountIsOffBudget = try await database.accountIsOffBudget(request.accountID)
        let options = ImportReconcileOptions.csv
        let transferPayeeIDs = Self.transferPayeeIDs(payees)
        let candidates = TransactionCSVImportCandidates.candidates(
            rows: rows,
            lookup: TransactionCSVImportLookup(
                payeeIDByName: Self.payeeIDByName(payees),
                transferPayeeIDs: transferPayeeIDs,
                categoryIDByName: Self.categoryIDByName(categories)
            ),
            options: options
        )
        let previews = try await database.previewRules(
            for: candidates.map { ImportReconcileProjection.previewDraft(for: $0, accountID: request.accountID) },
            dateTimeZone: ImportReconcileProjection.ruleDateTimeZone
        )
        guard previews.count == candidates.count else {
            throw LocalFirstError.invalidLocalWrite("missing import rule preview")
        }
        let projection = ImportReconcileProjection.project(
            candidates: candidates,
            previews: previews,
            accountID: request.accountID,
            accountIsOffBudget: accountIsOffBudget
        )
        if let moved = projection.movedSources.first {
            throw TransactionCSVImportError.unsupportedAccountMove(line: rows[moved].sourceLine)
        }
        let reconciled = try await reconcileProjectedImport(
            database: database,
            accountID: request.accountID,
            accountIsOffBudget: accountIsOffBudget,
            candidateDayIDs: candidates.map(\.dayID),
            importedIDs: Set(candidates.compactMap(\.financialID)),
            projected: projection.candidates,
            transferPayeeIDs: transferPayeeIDs,
            options: options
        )

        guard transactionFeedRequestIdentity.sessionID == sessionID,
              generation == budgetSessionGeneration,
              self.database === database,
              openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        return TransactionCSVImportReview(
            rows: Self.reviewRows(
                rows: rows,
                projection: projection,
                reconciled: reconciled,
                transferPayeeIDs: transferPayeeIDs
            ),
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

        var inserts: [BankSyncReconciliation.Candidate] = []
        var matches: [BudgetDatabase.TransactionCSVImportMatch] = []
        for reviewRow in request.rows {
            switch reviewRow.outcome {
            case .insert(let candidate, _):
                inserts.append(candidate)
            case .update(let update, let existing):
                matches.append(BudgetDatabase.TransactionCSVImportMatch(
                    line: reviewRow.row.sourceLine, update: update, existing: existing
                ))
            case .unchanged, .reconciled, .skippedByRule:
                continue
            }
        }
        guard !inserts.isEmpty || !matches.isEmpty else {
            return TransactionCSVImportApplyResult(insertedCount: 0, updatedCount: 0)
        }

        let accountIsOffBudget = try await database.accountIsOffBudget(request.accountID)
        var builder = LocalFirstSyncMessageBuilder()
        // Pinned Actual stamps inserted rows with a descending sort_order from
        // Date.now() so file order survives on display.
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000
        let writes = try await importReconcileWrites(
            database: database,
            accountID: request.accountID,
            accountIsOffBudget: accountIsOffBudget,
            updates: matches.map { (update: $0.update, existing: $0.existing) },
            inserts: inserts,
            options: .csv,
            sortOrder: { sortOrderBase - Double($0) },
            builder: &builder
        )
        try requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )
        do {
            try await database.commitTransactionCSVImport(
                accountID: request.accountID,
                messages: writes.messages,
                matches: matches,
                expectedAbsentImportedIDs: BudgetDatabase.ImportedIDAbsence(
                    accountID: request.accountID,
                    importedIDs: inserts.compactMap(\.financialID)
                )
            )
        } catch LocalFirstError.importedTransactionConflict {
            // Another writer imported one of these ids after the review.
            throw TransactionCSVImportError.reviewChanged
        }
        // The import is committed and cannot be repeated, so it finishes on the
        // durable tail; a pending refresh never turns it into a failure.
        _ = await finishDurableTransactionWrite(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration,
            accountIDs: Array(writes.affectedAccountIDs)
        )
        return TransactionCSVImportApplyResult(
            insertedCount: writes.insertedCount,
            updatedCount: writes.updatedCount
        )
    }

    /// One outcome per CSV row, in file order. A row the plan does not mention
    /// was dropped by a delete-transaction rule.
    private static func reviewRows(
        rows: [TransactionCSVImportRow],
        projection: ImportReconcileProjection.Result,
        reconciled: ImportReconcileOutcome,
        transferPayeeIDs: Set<String>
    ) -> [TransactionCSVImportReviewRow] {
        let existingByID = Dictionary(
            reconciled.existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var outcomes = [TransactionCSVImportReviewRow.Outcome?](repeating: nil, count: rows.count)
        for (entry, projectedIndex) in zip(reconciled.plan.entries, reconciled.plan.sources) {
            let rowIndex = projection.sources[projectedIndex]
            switch entry {
            case .insert(let candidate):
                outcomes[rowIndex] = .insert(
                    candidate,
                    isTransfer: candidate.payeeID.map(transferPayeeIDs.contains) ?? false
                )
            case .update(let update):
                if let existing = existingByID[update.existingID] {
                    outcomes[rowIndex] = .update(update, existing: existing)
                } else {
                    outcomes[rowIndex] = .unchanged
                }
            case .unchanged(let id):
                outcomes[rowIndex] = existingByID[id]?.reconciled == true ? .reconciled : .unchanged
            case .skippedDeleted:
                // CSV re-imports deleted rows (reimportDeleted: true), so no id is suppressed.
                outcomes[rowIndex] = .unchanged
            }
        }
        return zip(rows, outcomes).map {
            TransactionCSVImportReviewRow(row: $0, outcome: $1 ?? .skippedByRule)
        }
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
