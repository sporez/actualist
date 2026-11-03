import Foundation

/// Wallet import runs the shared import step the way Bank Sync does (upstream
/// `reconcileTransactions` for a synced account): rules, then
/// `reconcileProjectedImport` with `.bankSync` options, then
/// `importReconcileWrites`, in one commit. The match is not strict: a device
/// gives Wallet transactions its own IDs, so a row stored with another ID
/// still matches by amount and date and takes the new ID (sync.ts, "account
/// sync sources can give two different transaction IDs"). Like upstream, an
/// import never learns categories.
extension LocalFirstActualStore {
    func existingImportedIDs(budgetID: String, accountID: String) async throws -> Set<String> {
        let database = try requireDatabase(for: budgetID)
        return try await database.existingImportedIDs(accountID: accountID)
    }

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
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let accountIsOffBudget = try await database.accountIsOffBudget(accountID)
        // loot-core resolves `trans.payee` before `runRules`, so Payee-is
        // conditions and the payee match pass see existing non-transfer payees.
        let payeeIDsByName = try await database.fetchPayees().reduce(
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
        let previews = try await database.previewRules(
            for: candidates.map { ImportReconcileProjection.previewDraft(for: $0, accountID: accountID) },
            dateTimeZone: .autoupdatingCurrent
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
        let outcome = try await reconcileProjectedImport(
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
        let writes = try await importReconcileWrites(
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
        await testSeams?.walletImportBeforeCommitHook?(attempt)
        #endif
        guard self.database === database, generation == budgetSessionGeneration else {
            throw CancellationError()
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            writes.messages,
            expectedAbsentImportedIDs: BudgetDatabase.ImportedIDAbsence(
                accountID: accountID,
                importedIDs: inserts.compactMap(\.financialID)
            ),
            expectedMatchedRows: BudgetDatabase.MatchedRowsUnchanged(
                accountID: accountID,
                reviewed: outcome.reviewedRows
            )
        )

        // A pending refresh invalidates the feed caches; the import itself
        // is complete and not repeatable, so its summary never reports it.
        _ = await finishDurableTransactionWrite(
            database: database,
            budgetID: budgetID,
            generation: generation,
            accountIDs: Array(writes.affectedAccountIDs)
        )
        return result
    }
}
