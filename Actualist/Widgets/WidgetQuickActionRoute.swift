import Foundation

struct WidgetQuickActionRoute {
    let route: AppRoute
    let tab: AppTab
    var settingsPage: SettingsPage?

    init(action: WidgetQuickAction, now: Date = Date()) {
        switch action {
        case .addExpense:
            route = .newTransaction(ShortcutEditorPrefill(direction: .spend))
            tab = .spending
        case .addIncome:
            route = .newTransaction(ShortcutEditorPrefill(direction: .inflow))
            tab = .spending
        case .spending:
            route = .tab(.spending)
            tab = .spending
        case .budget:
            route = .tab(.budget)
            tab = .budget
        case .accounts:
            route = .tab(.accounts)
            tab = .accounts
        case .reports:
            route = .tab(.reports)
            tab = .reports
        case .uncategorized:
            route = .uncategorized(month: WidgetMonthID.current(now: now))
            tab = .budget
        case .history:
            route = .history
            tab = .budget
        case .settings:
            route = .settings
            tab = .budget
        case .templates, .payees, .rules, .bankSync, .reportOrder,
             .appearance, .privacy, .connection, .budgetData, .advanced, .support:
            route = .settings
            tab = .budget
            settingsPage = Self.page(for: action)
        }
    }

    private static func page(for action: WidgetQuickAction) -> SettingsPage? {
        switch action {
        case .templates: .templates
        case .payees: .payees
        case .rules: .rules
        case .bankSync: .bankSync
        case .reportOrder: .reports
        case .appearance: .appearance
        case .privacy: .privacy
        case .connection: .connection
        case .budgetData: .budgetData
        case .advanced: .advanced
        case .support: .support
        default: nil
        }
    }
}
