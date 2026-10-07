import Foundation

/// Name lookups the CSV mapping needs from the open budget.
struct TransactionCSVImportLookup: Sendable {
    /// Lowercased payee name → payee ID for live payees, transfer payees
    /// included: upstream resolves a row's payee with `getPayeeByName`, which
    /// does not exclude them, and a row becomes a transfer only by resolving
    /// to one.
    let payeeIDByName: [String: String]
    /// Payee IDs whose payee carries a transfer account.
    let transferPayeeIDs: Set<String>
    /// Lowercased category name → category ID for live categories.
    let categoryIDByName: [String: String]
}

/// Maps normalized CSV rows onto the shared reconciler's candidates, the same
/// shape upstream's `normalizeTransactions` hands to `matchTransactions`
/// (`sync.ts`). Pure: rule projection, matching and message construction
/// happen downstream.
enum TransactionCSVImportCandidates {
    static func candidates(
        rows: [TransactionCSVImportRow],
        lookup: TransactionCSVImportLookup,
        options: ImportReconcileOptions
    ) -> [BankSyncReconciliation.Candidate] {
        rows.map { candidate(for: $0, lookup: lookup, options: options) }
    }

    static func candidate(
        for row: TransactionCSVImportRow,
        lookup: TransactionCSVImportLookup,
        options: ImportReconcileOptions
    ) -> BankSyncReconciliation.Candidate {
        // `normalizeTransactions`: the payee name is trimmed and normalized,
        // an empty one is a null payee, and imported_payee is that same text.
        let payeeName = row.payeeName.isEmpty ? nil : options.payeeNameNormalization.normalize(row.payeeName)
        return BankSyncReconciliation.Candidate(
            financialID: row.importedID.flatMap { $0.isEmpty ? nil : $0 },
            // ISO calendar day to YYYYMMDD: no instant, no time zone.
            dayID: row.dateText.replacingOccurrences(of: "-", with: ""),
            amountMinorUnits: row.amountMinorUnits,
            payeeID: payeeName.flatMap { lookup.payeeIDByName[$0.lowercased()] },
            payeeName: payeeName,
            notes: row.notes,
            categoryID: row.categoryName.flatMap { lookup.categoryIDByName[$0.lowercased()] },
            cleared: row.cleared ?? false,
            importedPayee: payeeName,
            clearedIsExplicit: row.cleared != nil
        )
    }
}
