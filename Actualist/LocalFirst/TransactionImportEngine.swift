import Foundation

/// The file-import steps between parsing and writing that need no store or
/// session state: name lookups for the candidates, each row's review outcome,
/// and the split of reviewed rows into inserts and re-checked matches.
/// `LocalFirstActualStore` keeps the orchestration (session guards, rule
/// preview, the shared reconcile and the commit).
enum TransactionImportEngine {
    /// Name lookups from the open budget's live payees and its categories in
    /// Actual's list order (`TransactionImportSQL.categoryList`).
    static func lookup(
        payees: [ActualPayee],
        categories: [ImportCategoryMatcher.Category]
    ) -> TransactionCSVImportLookup {
        TransactionCSVImportLookup(
            payeeIDByName: payeeIDByName(payees),
            transferPayeeIDs: transferPayeeIDs(payees),
            categories: ImportCategoryMatcher(categories: categories)
        )
    }

    /// One outcome per file row, in file order. A row the plan does not
    /// mention was dropped by a delete-transaction rule.
    static func reviewRows(
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
                // The account's reimport-deleted preference suppressed this deleted row's id.
                outcomes[rowIndex] = .unchanged
            }
        }
        return zip(rows, outcomes).map {
            TransactionCSVImportReviewRow(row: $0, outcome: $1 ?? .skippedByRule)
        }
    }

    /// The writes a reviewed import asks for. Rows that write nothing are
    /// dropped; a match carries its file line for the commit's re-check.
    static func writePlan(
        for rows: [TransactionCSVImportReviewRow]
    ) -> (inserts: [BankSyncReconciliation.Candidate], matches: [TransactionImportSQL.Match]) {
        var inserts: [BankSyncReconciliation.Candidate] = []
        var matches: [TransactionImportSQL.Match] = []
        for reviewRow in rows {
            switch reviewRow.outcome {
            case .insert(let candidate, _):
                inserts.append(candidate)
            case .update(let update, let existing):
                matches.append(TransactionImportSQL.Match(
                    line: reviewRow.row.sourceLine, update: update, existing: existing
                ))
            case .unchanged, .reconciled, .skippedByRule:
                continue
            }
        }
        return (inserts, matches)
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
}
