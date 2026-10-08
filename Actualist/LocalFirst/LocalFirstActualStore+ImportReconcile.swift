import Foundation

/// What an import's reconcile step decided: the plan and the rows it matched
/// against. The caller turns the plan into messages with `importReconcileWrites`.
struct ImportReconcileOutcome: Sendable {
    let plan: BankSyncReconciliation.Plan
    let existing: [BankSyncReconciliation.Existing]
}

/// The messages and counters for a plan's matched updates and inserts.
struct ImportReconcileWrites {
    var messages: [ActualSyncDecodedMessage] = []
    /// Local transaction IDs created per account, in insertion order. A
    /// transfer insert also lists its paired leg under the other account.
    var insertedIDsByAccount: [String: [String]] = [:]
    /// The importing account plus every transfer counterpart.
    var affectedAccountIDs: Set<String>
    var insertedCount = 0
    var updatedCount = 0
}

/// The account-agnostic import reconcile step shared by Bank Sync and CSV
/// import (main-to-dev D4, upstream `reconcileTransactions`, sync.ts):
/// rule projection (`ImportReconcileProjection`) → `reconcileProjectedImport`
/// → `importReconcileWrites`. The caller owns what is specific to its source:
/// Bank Sync's link identity, generation, opening balance and completion
/// messages; CSV's file mapping and review.
extension LocalFirstActualStore {
    /// Reads the matching window and plans the projected candidates.
    ///
    /// - Parameters:
    ///   - candidateDayIDs: The days before rules ran; they bound the read, so
    ///     a rule that moves a date cannot hide a row from matching.
    ///   - importedIDs: Ids matched exactly wherever the stored row sits,
    ///     because the exact tier is not date-bound (`imported_id = ?`).
    func reconcileProjectedImport(
        database: BudgetDatabase,
        accountID: String,
        accountIsOffBudget: Bool,
        candidateDayIDs: [String],
        importedIDs: Set<String> = [],
        projected: [BankSyncReconciliation.Candidate],
        transferPayeeIDs: Set<String>,
        options: ImportReconcileOptions
    ) async throws -> ImportReconcileOutcome {
        let existing = try await database.bankSyncExistingRows(
            accountID: accountID,
            window: Self.monthWidenedWindow(candidateDayIDs: candidateDayIDs),
            orImportedIDs: importedIDs
        )
        let suppressed: Set<String>
        switch options.reimportDeleted {
        case true?: suppressed = []
        case false?: suppressed = try await database.bankSyncSuppressedFinancialIDs(
            accountID: accountID, ignoringPreference: true
        )
        case nil: suppressed = try await database.bankSyncSuppressedFinancialIDs(accountID: accountID)
        }
        let plan = await BankSyncReconciliation.planOffMain(
            candidates: projected,
            existing: existing,
            suppressedFinancialIDs: suppressed,
            accountIsOffBudget: accountIsOffBudget,
            transferPayeeIDs: transferPayeeIDs,
            options: options
        )
        return ImportReconcileOutcome(plan: plan, existing: existing)
    }

    /// Matched updates first, then inserts, each insert preceded by the
    /// messages that create its payee. Bank Sync prepends its opening balance
    /// and appends its completion messages around this.
    ///
    /// - Parameter sortOrder: The `sort_order` of the insert at an index.
    func importReconcileWrites(
        database: BudgetDatabase,
        accountID: String,
        accountIsOffBudget: Bool,
        updates: [(update: BankSyncReconciliation.MatchedUpdate, existing: BankSyncReconciliation.Existing)],
        inserts: [BankSyncReconciliation.Candidate],
        options: ImportReconcileOptions,
        sortOrder: (Int) -> Double,
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> ImportReconcileWrites {
        var writes = ImportReconcileWrites(affectedAccountIDs: [accountID])
        for (update, existing) in updates {
            try Task.checkCancellation()
            writes.messages.append(contentsOf: try await database.makeBankSyncMatchUpdateMessages(
                update: update,
                existing: existing,
                accountIsOffBudget: accountIsOffBudget,
                clearsMissingImportIdentity: !options.isBankSyncAccount,
                builder: &builder
            ))
            writes.updatedCount += 1
        }

        var resolvedPayeeIDs: [String: String] = [:]
        var knownPayees: [ActualPayee]?
        for (index, candidate) in inserts.enumerated() {
            try Task.checkCancellation()
            let transactionID = UUID().uuidString
            let payeeResolution = try await resolveReconcileInsertPayee(
                candidate: candidate,
                resolvedPayeeIDs: &resolvedPayeeIDs,
                knownPayees: &knownPayees,
                database: database,
                builder: &builder
            )
            let transferDestinationID = candidate.isSplit
                ? nil
                : try await database.transferAccountID(ifPayee: payeeResolution.payeeID)
            let draft = try importInsertDraft(
                candidate: candidate,
                accountID: accountID,
                payeeID: payeeResolution.payeeID,
                sortOrder: sortOrder(index),
                accountIsOffBudget: accountIsOffBudget,
                options: options
            )
            let transactionMessages: [ActualSyncDecodedMessage]
            if draft.isSplit {
                transactionMessages = try await database.createSplitTransactionMessages(
                    draft: draft,
                    parentTransactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
            } else if let transferDestinationID, let payeeID = payeeResolution.payeeID {
                let transfer = try await database.createTransferTransactionMessages(
                    draft: draft,
                    sourceTransactionID: transactionID,
                    payeeID: payeeID,
                    builder: &builder
                )
                transactionMessages = transfer.messages + (try await database.makeImportedIdentityMessages(
                    transactionID: transactionID,
                    importedID: candidate.financialID,
                    importedPayee: candidate.importedPayee,
                    builder: &builder
                ))
                writes.affectedAccountIDs.insert(transferDestinationID)
                writes.insertedIDsByAccount[transferDestinationID, default: []].append(transfer.pairedTransactionID)
            } else {
                transactionMessages = try await database.createSimpleTransactionMessages(
                    draft,
                    transactionID: transactionID,
                    payeeID: payeeResolution.payeeID,
                    builder: &builder
                )
            }
            writes.messages.append(contentsOf: payeeResolution.messages)
            writes.messages.append(contentsOf: transactionMessages)
            writes.insertedIDsByAccount[accountID, default: []].append(transactionID)
            writes.insertedCount += 1
        }
        return writes
    }

    private func importInsertDraft(
        candidate: BankSyncReconciliation.Candidate,
        accountID: String,
        payeeID: String?,
        sortOrder: Double,
        accountIsOffBudget: Bool,
        options: ImportReconcileOptions
    ) throws -> TransactionDraft {
        guard let date = BankSyncAmounts.date(fromDayID: candidate.dayID) else {
            throw LocalFirstError.invalidLocalWrite("missing bank sync download")
        }
        var draft = TransactionDraft(
            accountID: accountID,
            date: date,
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: payeeID,
            payeeName: candidate.payeeName ?? "",
            categoryID: accountIsOffBudget ? nil : candidate.categoryID,
            notes: candidate.notes,
            // `trans.cleared ?? defaultCleared` (sync.ts).
            cleared: candidate.clearedIsExplicit ? candidate.cleared : options.defaultCleared,
            isTransfer: false
        )
        draft.importedPayee = candidate.importedPayee
        draft.importedID = candidate.financialID
        draft.sortOrder = sortOrder
        draft.scheduleID = candidate.scheduleID
        if candidate.isSplit {
            draft.splits = candidate.splits.map {
                TransactionSplitDraft(
                    id: nil,
                    categoryID: accountIsOffBudget ? nil : $0.categoryID,
                    categoryName: nil,
                    amountMinorUnits: $0.amountMinorUnits,
                    payeeID: $0.payeeID,
                    notes: $0.notes,
                    sortOrder: $0.sortOrder
                )
            }
        }
        return draft
    }

    /// A row with no payee text stays payee-less (CSV allows it; Bank Sync
    /// rejects such a row before it becomes a candidate).
    private func resolveReconcileInsertPayee(
        candidate: BankSyncReconciliation.Candidate,
        resolvedPayeeIDs: inout [String: String],
        knownPayees: inout [ActualPayee]?,
        database: BudgetDatabase,
        builder: inout LocalFirstSyncMessageBuilder
    ) async throws -> (payeeID: String?, messages: [ActualSyncDecodedMessage]) {
        if let selectedPayeeID = candidate.payeeID, !selectedPayeeID.isEmpty {
            return (selectedPayeeID, [])
        }
        // Splits carry no payee of their own; the parent name drives creation.
        let name = candidate.payeeName ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, [])
        }
        let key = name.lowercased()
        if let cachedID = resolvedPayeeIDs[key] {
            return (cachedID, [])
        }
        if knownPayees == nil { knownPayees = try await database.fetchPayees() }
        let resolution = try await database.resolveOrCreatePayeeMessages(
            selectedPayeeID: nil,
            payeeName: name,
            knownPayees: knownPayees,
            builder: &builder
        )
        resolvedPayeeIDs[key] = resolution.payeeID
        return resolution
    }
}
