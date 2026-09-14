import Foundation

enum TransactionRulePreviewProjection {
    static func applying(
        _ preview: TransactionRulePreview,
        to draft: TransactionDraft
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: preview.accountID ?? draft.accountID,
            date: preview.date ?? draft.date,
            amountMinorUnits: preview.amountMinorUnits ?? draft.amountMinorUnits,
            payeeID: preview.payeeID ?? draft.payeeID,
            payeeName: draft.payeeName,
            categoryID: preview.splits.isEmpty ? preview.categoryID : nil,
            // Rule preview carries the final nullable notes value. Nil means
            // remove notes, not "leave the draft unchanged."
            notes: preview.notes,
            cleared: preview.cleared ?? draft.cleared,
            isTransfer: draft.isTransfer,
            importedPayee: draft.importedPayee,
            importedID: draft.importedID,
            sortOrder: draft.sortOrder,
            reconciled: draft.reconciled,
            isParent: !preview.splits.isEmpty || draft.isParent,
            splits: preview.splits.isEmpty ? draft.splits : preview.splits,
            scheduleID: preview.scheduleID ?? draft.scheduleID
        )
    }
}
