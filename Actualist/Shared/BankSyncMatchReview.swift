import Foundation

/// Pure projection of the reconciler's matched updates into exact review
/// effects. The store supplies names from the opened budget; no additional
/// matching or write decisions are made here.
enum BankSyncMatchReview {
    static func details(
        updates: [BankSyncReconciliation.MatchedUpdate],
        existing: [BankSyncReconciliation.Existing],
        payeeNames: [String: String],
        categoryNames: [String: String]
    ) -> [BankSyncReview.MatchDetail] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        return updates.compactMap { update in
            guard let row = existingByID[update.existingID] else {
                return nil
            }
            return detail(
                update: update,
                row: row,
                payeeNames: payeeNames,
                categoryNames: categoryNames
            )
        }
    }

    private static func detail(
        update: BankSyncReconciliation.MatchedUpdate,
        row: BankSyncReconciliation.Existing,
        payeeNames: [String: String],
        categoryNames: [String: String]
    ) -> BankSyncReview.MatchDetail {
        var changes: [BankSyncReview.MatchChange] = []
        if let financialID = update.financialID, financialID != row.financialID {
            changes.append(.init(
                field: row.financialID == nil ? .bankIDAttached : .bankIDReplaced,
                oldValue: nil,
                newValue: nil
            ))
        }
        if let payeeID = update.payeeID, payeeID != row.payeeID {
            changes.append(.init(
                field: .payee,
                oldValue: row.payeeID.flatMap { payeeNames[$0] },
                newValue: payeeNames[payeeID] ?? "Unknown payee"
            ))
        }
        if let categoryID = update.categoryID, categoryID != row.categoryID {
            changes.append(.init(
                field: .category,
                oldValue: row.categoryID.flatMap { categoryNames[$0] },
                newValue: categoryNames[categoryID] ?? "Unknown category"
            ))
        }
        if let importedPayee = update.importedPayee, importedPayee != row.importedPayee {
            changes.append(.init(
                field: .bankPayee,
                oldValue: row.importedPayee,
                newValue: importedPayee
            ))
        }
        if let notes = update.notes, notes != row.notes {
            changes.append(.init(field: .notes, oldValue: row.notes, newValue: notes))
        }
        if update.cleared != row.cleared {
            changes.append(.init(
                field: .cleared,
                oldValue: String(row.cleared),
                newValue: String(update.cleared)
            ))
        }
        if !update.childIDs.isEmpty {
            changes.append(.init(
                field: .splitChildrenCleared,
                oldValue: nil,
                newValue: String(update.childIDs.count)
            ))
        }
        return BankSyncReview.MatchDetail(
            transactionID: row.id,
            dayID: row.dayID,
            amountMinorUnits: row.amountMinorUnits,
            currentPayeeName: row.payeeID.flatMap { payeeNames[$0] }
                ?? row.importedPayee
                ?? update.importedPayee,
            changes: changes
        )
    }
}
