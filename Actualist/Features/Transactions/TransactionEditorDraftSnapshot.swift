import Foundation

/// The user-editable fields of a transaction draft, compared against the
/// baseline captured when the editor finished loading. Defaults the editor
/// fills in during load (default account, prefilled payee) are part of the
/// baseline, so only the user's own edits count as unsaved.
struct TransactionEditorDraftSnapshot: Equatable {
    let kind: TransactionFlowKind
    let amountDigits: String
    let payeeName: String
    let selectedPayeeID: String?
    let selectedAccountID: String?
    let day: DateComponents
    let notes: String
    /// `nil` when editing: the cleared toggle commits immediately there, so
    /// it never leaves anything unsaved.
    let isCleared: Bool?
    let splitState: TransactionSplitEditorState
}

extension TransactionEditorViewModel {
    var draftSnapshot: TransactionEditorDraftSnapshot {
        TransactionEditorDraftSnapshot(
            kind: kind,
            amountDigits: amountDigits,
            payeeName: payeeName,
            selectedPayeeID: selectedPayeeID,
            selectedAccountID: selectedAccountID,
            day: Calendar.current.dateComponents([.year, .month, .day], from: date),
            notes: notes,
            isCleared: isEditing ? nil : isCleared,
            splitState: splitState
        )
    }

    /// Records the loaded draft once; later loads keep the original baseline
    /// so edits made in between still count as unsaved.
    func captureDraftBaselineIfNeeded() {
        if draftBaseline == nil { draftBaseline = draftSnapshot }
    }

    /// Whether closing the editor would discard user edits. False until the
    /// editor has loaded, so a sheet can always close while it is loading.
    var hasUnsavedChanges: Bool {
        guard let draftBaseline else { return false }
        return draftSnapshot != draftBaseline
    }
}
