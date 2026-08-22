import Foundation

enum AppRoute: Equatable {
    case tab(AppTab)
    case account(id: String)
    case category(id: String, month: String)
    case uncategorized(month: String)
    case newTransaction(ShortcutEditorPrefill)
}

struct ShortcutEditorPrefill: Equatable {
    var accountID: String?
    var amountMinorUnits: Int?
    var payeeName: String?
    var categoryID: String?
    var categoryName: String?
    var notes: String?
    var direction: TransactionFlowKind = .spend
}
