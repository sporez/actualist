import Foundation

/// What an edit of a simple (non-split) row changes, measured against the
/// caller's loaded baseline. Mirrors loot-core `diffItems`: only differing
/// fields are written, so a stale editor cannot overwrite a remote edit to a
/// field it did not touch.
struct SimpleRowChange {
    let baseline: ActualTransaction
    let draft: TransactionDraft
    let payeeID: String
    let category: String?
    let dateValue: Int

    var accountChanged: Bool { draft.accountID != baseline.account }
    var payeeChanged: Bool { payeeID != baseline.payee }
    var amountChanged: Bool { draft.amountMinorUnits != (baseline.amount ?? 0) }
    var notesChanged: Bool { draft.notes != baseline.notes }
    var categoryChanged: Bool { category != baseline.category }

    /// Dates compare as digits (baseline `2026-03-05` against `20260305`).
    var dateChanged: Bool { BudgetDatabase.packedDate(fromISO: baseline.date) != dateValue }
}

extension BudgetDatabase {
    /// The main row's changed cells. `isParent`, `parent_id`, `isChild`,
    /// `tombstone` and `error` are never written here: they are copied from the
    /// baseline so `messagesForChangedFields` sees no difference.
    func simpleRowDiffMessages(
        transactionID: String,
        change: SimpleRowChange,
        columns: TransactionRowColumns,
        builder: inout LocalFirstSyncMessageBuilder
    ) throws -> [ActualSyncDecodedMessage] {
        let baseline = change.baseline
        let old = SplitTransactionRecord(
            id: transactionID,
            amount: baseline.amount ?? 0,
            account: baseline.account,
            date: baseline.date,
            category: baseline.category,
            payee: baseline.payee,
            notes: baseline.notes,
            cleared: baseline.cleared?.boolValue ?? false,
            reconciled: baseline.reconciled
        )
        var new = old
        new.account = change.draft.accountID
        new.amount = change.draft.amountMinorUnits
        new.payee = change.payeeID
        new.category = change.category
        new.notes = change.draft.notes
        new.cleared = change.draft.cleared
        new.reconciled = change.draft.reconciled
        if change.dateChanged {
            new.date = Self.isoDateString(fromPacked: change.dateValue)
        }
        var messages = try messagesForChangedFields(from: old, to: new, columns: columns, builder: &builder)
        if let scheduleID = change.draft.scheduleID, columns.hasSchedule, scheduleID != baseline.schedule {
            messages.append(
                try builder.makeMessage(
                    dataset: "transactions",
                    row: transactionID,
                    column: "schedule",
                    value: .string(scheduleID)
                )
            )
        }
        return messages
    }
}
