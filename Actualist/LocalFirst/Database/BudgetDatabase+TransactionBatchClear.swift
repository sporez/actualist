import Foundation
import GRDB

extension BudgetDatabase {
    /// Clear for a selected split parent or child. Actual's `updateTransaction`
    /// rebuilds every child with `makeChild`, which copies the parent's
    /// `cleared`. Setting it on a parent therefore reaches its children, and a
    /// child alone cannot diverge from its parent.
    ///
    /// Only `cleared` is written. `makeChild` also resets other child fields
    /// (reconciled, transfer link) that Clear must not touch, and a reconciled
    /// row keeps its cleared state. The change goes through
    /// `messagesForChangedFields`, not `persistFamilyChange`, so no transfer
    /// reconciliation runs for rows whose transfer fields did not change.
    func batchClearFamilyMessages(
        transactionID: String,
        target: Bool,
        overlay: inout BatchFamilyOverlay,
        columns: TransactionRowColumns,
        db: Database,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        guard try loadBatchFamily(containing: transactionID, overlay: &overlay, columns: columns, db: db),
              let family = overlay.family(containing: transactionID),
              var selected = overlay.record(transactionID) else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        selected.cleared = target
        let result = SplitTransactionFamilyOps.updateTransaction(family, transaction: selected)
        guard !result.data.isEmpty else {
            throw LocalFirstError.invalidLocalWrite("missing transaction")
        }
        let oldByID = Dictionary(uniqueKeysWithValues: family.map { ($0.id, $0) })
        var messages: [ActualSyncDecodedMessage] = []
        var updated: [SplitTransactionRecord] = []
        for row in result.data {
            guard let old = oldByID[row.id] else {
                updated.append(row)
                continue
            }
            var next = old
            if old.reconciled != true { next.cleared = row.cleared }
            updated.append(next)
            if old.cleared != next.cleared {
                messages += try messagesForChangedFields(from: old, to: next, columns: columns, builder: &builder)
            }
        }
        overlay.replaceFamily(root: family[0].id, with: updated)
        return messages
    }
}
