import Foundation

/// The provider-side mapping of one account's download into reconcile
/// candidates: the import-pending filter, the ID, currency, amount, date and
/// payee checks, custom field mappings and note escaping (loot-core
/// `normalizeBankSyncTransactions`). Pure; the planner runs it for every
/// account and the Enable Banking oracle replay runs it on Actual's own
/// server output.
enum BankSyncDownloadPreparation {
    struct Prepared {
        let download: SimpleFINAccountDownload
        var candidates: [BankSyncReconciliation.Candidate] = []
        var ruleDrafts: [TransactionDraft] = []
        var projectedCandidates: [BankSyncReconciliation.Candidate] = []
        var problems: [BankSyncReview.Problem] = []

        init(download: SimpleFINAccountDownload) {
            self.download = download
        }
    }

    static func prepare(
        _ download: SimpleFINAccountDownload,
        provider: BankSyncProviderKind,
        accountID: String,
        currency: BudgetCurrency,
        payeeIDsByName: [String: String],
        preferences: BankSyncLinkSQL.BankSyncImportPreferences
    ) throws -> Prepared {
        var prepared = Prepared(download: download)
        let mappings: BankSyncFieldMapping.Mappings
        if let json = preferences.customMappingsJSON {
            do {
                mappings = try BankSyncFieldMapping.parse(json)
            } catch {
                prepared.problems.append(.invalidCustomMapping)
                return prepared
            }
        } else {
            mappings = .defaults
        }
        for transaction in download.transactions {
            try Task.checkCancellation()
            // Actual skips uncleared downloads when import-pending is false,
            // before rules, matching, payee creation, or opening-balance math.
            if !preferences.importPending && transaction.booked != true {
                continue
            }
            let financialID = transaction.id.flatMap { id in
                id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : id
            }
            // Enable Banking sends an empty `transactionId` when the bank gives
            // neither an entry reference nor a transaction ID. Actual imports
            // the row without an imported ID and relies on fuzzy matching.
            // A SimpleFIN row always has an ID, so a missing one is unreadable.
            if financialID == nil, provider == .simpleFIN {
                prepared.problems.append(.init(
                    remoteTransactionID: nil,
                    message: "Missing transaction ID"
                ))
                continue
            }
            let problemID = financialID
            guard let transactionCurrency = BankSyncAmounts.normalizedCurrencyCode(
                transaction.currency
            ) else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Missing transaction currency"
                ))
                continue
            }
            guard currency.accepts(transactionCurrency) else {
                let budgetLabel = currency.code.isEmpty ? "none" : currency.code.uppercased()
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Currency mismatch (\(transactionCurrency) bank transaction, \(budgetLabel) budget)"
                ))
                continue
            }
            guard let amount = BankSyncAmounts.minorUnits(
                fromDecimal: transaction.amount,
                currency: currency
            ) else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Unreadable amount"
                ))
                continue
            }
            guard let mapped = BankSyncFieldMapping.resolve(
                transaction: transaction,
                amountMinorUnits: amount,
                mappings: mappings,
                importNotes: preferences.importNotes
            ) else {
                prepared.problems.append(.missingMappingSide(
                    remoteTransactionID: problemID,
                    isPayment: amount <= 0
                ))
                continue
            }
            guard let dayID = mapped.dateUnixSeconds.map(BankSyncAmounts.dayID(fromUnixSeconds:)) else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Unreadable date"
                ))
                continue
            }
            let payeeName = mapped.payeeName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard payeeName?.isEmpty == false else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Missing payee"
                ))
                continue
            }
            let candidate = BankSyncReconciliation.Candidate(
                financialID: financialID,
                dayID: dayID,
                amountMinorUnits: amount,
                payeeID: payeeName.flatMap { payeeIDsByName[$0.lowercased()] },
                payeeName: payeeName,
                notes: mapped.notes,
                categoryID: nil,
                // Actual core uses `Boolean(trans.booked)`: an absent or
                // unreadable posted state must remain pending, not be asserted
                // as cleared.
                cleared: transaction.booked == true,
                importedPayee: payeeName
            )
            prepared.candidates.append(candidate)
            prepared.ruleDrafts.append(ImportReconcileProjection.previewDraft(
                for: candidate,
                accountID: accountID
            ))
        }
        return prepared
    }
}
