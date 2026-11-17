import Foundation

/// Transaction CSV export and import. The store owns it and injects it as the
/// export and import repositories; the feed caches stay on the store.
@MainActor
final class TransactionCSVWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }
}

extension TransactionCSVWorkflows: TransactionCSVExportRepositoryProtocol {
    func exportTransactionsCSV(_ request: TransactionCSVExportRequest) async throws -> TransactionCSVExport {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: request.budgetID)
        let sessionID = store.transactionFeedRequestIdentity.sessionID
        let rows = try await TransactionCSVExportSQL.fetchTransactionCSVExportRows(
            accountID: request.accountID,
            query: request.query,
            in: database
        )
        try Task.checkCancellation()
        guard store.transactionFeedRequestIdentity.sessionID == sessionID,
              store.database === database,
              store.openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        return await TransactionCSVEncoder().encode(rows)
    }
}

/// CSV import prepare/apply. Prepare is read-only: parse, all-or-nothing
/// validation, then the shared import reconcile (rules, matching) for review.
/// Apply receives the decided rows and writes them through the same shared step
/// as Bank Sync (`ImportReconcileSteps.importReconcileWrites`) in one atomic commit, with the
/// review's preconditions re-checked inside it. There is no second
/// reconcile implementation and no wallet or bank-sync routing.
extension TransactionCSVWorkflows: TransactionCSVImportRepositoryProtocol {
    func prepareTransactionCSVImport(
        _ request: TransactionCSVImportPreparationRequest
    ) async throws -> TransactionCSVImportReview {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: request.budgetID)
        let sessionID = store.transactionFeedRequestIdentity.sessionID
        let generation = store.budgetSessionGeneration

        let settings: ImportSettings
        if let chosen = request.settings {
            settings = chosen
        } else {
            let preferences = try await database.importPreferences(
                keys: ImportSettings.preferenceKeys(accountID: request.accountID)
            )
            settings = .saved(preferences: preferences, accountID: request.accountID, fileName: request.fileName)
        }
        let rows = try await TransactionCSVImportPipeline.rows(from: request.data, settings: settings)

        let payees = try await PayeeSQL.fetchPayees(orderedForPicker: false, in: database)
        let categories = try await database.importCategoryList()
        let accountIsOffBudget = try await AccountSQL.accountIsOffBudget(request.accountID, in: database)
        let options = ImportReconcileOptions.csv
        let lookup = TransactionImportEngine.lookup(payees: payees, categories: categories)
        let candidates = TransactionCSVImportCandidates.candidates(
            rows: rows,
            lookup: lookup,
            options: options
        )
        let previews = try await RulePreviewSQL.previewRules(
            for: candidates.map { ImportReconcileProjection.previewDraft(for: $0, accountID: request.accountID) },
            dateTimeZone: ImportReconcileProjection.ruleDateTimeZone,
            in: database
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
        let reconciled = try await ImportReconcileSteps.reconcileProjectedImport(
            database: database,
            accountID: request.accountID,
            accountIsOffBudget: accountIsOffBudget,
            candidateDayIDs: candidates.map(\.dayID),
            importedIDs: Set(candidates.compactMap(\.financialID)),
            projected: projection.candidates,
            options: options
        )

        guard store.transactionFeedRequestIdentity.sessionID == sessionID,
              generation == store.budgetSessionGeneration,
              store.database === database,
              store.openedBudgetID == request.budgetID else {
            throw CancellationError()
        }
        return TransactionCSVImportReview(
            rows: TransactionImportEngine.reviewRows(
                rows: rows,
                projection: projection,
                reconciled: reconciled,
                transferPayeeIDs: lookup.transferPayeeIDs
            ),
            sessionGeneration: generation
        )
    }

    func applyTransactionCSVImport(
        _ request: TransactionCSVImportApplyRequest
    ) async throws -> TransactionCSVImportApplyResult {
        try Task.checkCancellation()
        let database = try store.requireDatabase(for: request.budgetID)
        try store.requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )

        let (inserts, matches) = TransactionImportEngine.writePlan(for: request.rows)
        guard !inserts.isEmpty || !matches.isEmpty else {
            return TransactionCSVImportApplyResult(insertedCount: 0, updatedCount: 0)
        }

        let accountIsOffBudget = try await AccountSQL.accountIsOffBudget(request.accountID, in: database)
        var builder = LocalFirstSyncMessageBuilder()
        // Pinned Actual stamps inserted rows with a descending sort_order from
        // Date.now() so file order survives on display.
        let sortOrderBase = Date().timeIntervalSince1970 * 1_000
        let writes = try await ImportReconcileSteps.importReconcileWrites(
            database: database,
            accountID: request.accountID,
            accountIsOffBudget: accountIsOffBudget,
            updates: matches.map { (update: $0.update, existing: $0.existing) },
            inserts: inserts,
            options: .csv,
            sortOrder: { sortOrderBase - Double($0) },
            builder: &builder
        )
        try store.requireSyncSession(
            database: database,
            budgetID: request.budgetID,
            generation: request.sessionGeneration
        )
        do {
            try await database.commitTransactionCSVImport(
                accountID: request.accountID,
                messages: writes.messages,
                matches: matches,
                expectedAbsentImportedIDs: ImportedIDAbsence(
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
        _ = await store.finishDurableTransactionWrite(
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
}
