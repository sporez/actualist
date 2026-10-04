import Foundation

/// Row-level split edits. The split view calls these instead of mutating
/// `splitState` itself.
extension TransactionEditorViewModel {
    var canRemoveSplitRow: Bool { splitState.canRemoveSplitRow }

    func addSplit() {
        splitState.addChild()
    }

    func toggleSplitSign(rowID: String) {
        splitState.toggleAmountSign(id: rowID)
    }

    func splitNotes(rowID: String) -> String {
        splitState.splitRows.first(where: { $0.id == rowID })?.displayNotes ?? ""
    }

    func setSplitNotes(rowID: String, notes: String) {
        splitState.setNotes(id: rowID, notes: notes)
    }

    func setSplitCustomPayee(rowID: String, name: String) {
        splitState.setPayee(id: rowID, payeeID: nil, name: name, isTransfer: false)
    }

    func setSplitCategory(rowID: String, categoryID: String?, name: String?) {
        splitState.setCategory(id: rowID, categoryID: categoryID, name: name)
    }
}
