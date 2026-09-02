import Foundation

enum AppRoute: Equatable {
    case tab(AppTab)
    case account(id: String)
    case category(id: String, month: String)
    case uncategorized(month: String)
    case history
    case settings
    case newTransaction(ShortcutEditorPrefill)
}

struct ShortcutEditorPrefill: Equatable {
    var accountID: String?
    var amountMinorUnits: Int?
    var payeeID: String?
    var payeeName: String?
    var categoryID: String?
    var categoryName: String?
    var notes: String?
    var direction: TransactionFlowKind = .spend
}

enum AppRouteApplication {
    static func account(from route: AppRoute?, in accounts: [ActualAccount]) -> ActualAccount? {
        guard case .account(let id) = route else {
            return nil
        }
        return accounts.first(where: { $0.id == id })
    }

    static func category(
        from route: AppRoute?,
        in categories: [BudgetMonthCategory]
    ) -> (category: BudgetMonthCategory, month: String)? {
        guard case .category(let id, let month) = route else {
            return nil
        }
        guard let category = categories.first(where: { $0.id == id }) else {
            return nil
        }
        return (category, month)
    }

    static func uncategorizedMonth(from route: AppRoute?) -> String? {
        guard case .uncategorized(let month) = route else {
            return nil
        }
        return month
    }
}
