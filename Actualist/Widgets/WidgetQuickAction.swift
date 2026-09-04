import Foundation

enum WidgetQuickActionGroup: String, CaseIterable, Identifiable, Sendable {
    case transactions = "Transactions"
    case budget = "Budget"
    case accounts = "Accounts"
    case reports = "Reports"
    case settings = "Settings"

    var id: String { rawValue }
}

enum WidgetQuickAction: String, CaseIterable, Identifiable, Sendable {
    case addExpense = "add-expense"
    case addIncome = "add-income"
    case spending
    case uncategorized
    case budget
    case history
    case templates
    case accounts
    case payees
    case rules
    case bankSync = "bank-sync"
    case reports
    case reportOrder = "report-order"
    case settings
    case appearance
    case privacy
    case connection
    case budgetData = "budget-data"
    case advanced
    case support

    var id: String { rawValue }
    var title: String { metadata.title }
    var symbol: String { metadata.symbol }
    var group: WidgetQuickActionGroup { metadata.group }
    var detail: String { metadata.detail }

    static func matching(_ search: String = "") -> [WidgetQuickAction] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return WidgetQuickActionGroup.allCases.flatMap { group in
            allCases.filter { action in
                action.group == group && (query.isEmpty
                    || [action.title, action.detail, group.rawValue].contains { $0.localizedStandardContains(query) })
            }
        }
    }

    private var metadata: (title: String, symbol: String, group: WidgetQuickActionGroup, detail: String) {
        switch self {
        case .addExpense:
            ("Add Expense", "minus.circle.fill", .transactions, "Open a new expense for review and save.")
        case .addIncome:
            ("Add Income", "plus.circle.fill", .transactions, "Open a new income transaction for review and save.")
        case .spending:
            ("Spending", "banknote.fill", .transactions, "Browse transactions across all accounts.")
        case .uncategorized:
            ("Uncategorized", "tray.fill", .transactions, "Review uncategorized transactions across your budget.")
        case .budget:
            ("Budget", "list.bullet.rectangle.portrait.fill", .budget, "Open your budget and category balances.")
        case .history:
            ("History", "clock.arrow.circlepath", .budget, "Review recent changes to your budget.")
        case .templates:
            ("Templates", "sparkles", .budget, "Browse and edit category templates.")
        case .accounts:
            ("Accounts", "building.columns.fill", .accounts, "Browse accounts and balances.")
        case .payees:
            ("Payees", "person.2.fill", .transactions, "Manage payees and their names.")
        case .rules:
            ("Rules", "wand.and.stars", .transactions, "Manage transaction rules.")
        case .bankSync:
            ("Bank Sync", "arrow.triangle.2.circlepath", .accounts, "Open Bank Sync to download and review transactions.")
        case .reports:
            ("Reports", "chart.xyaxis.line", .reports, "Explore spending, trends, and net worth.")
        case .reportOrder:
            ("Report Order", "chart.bar.xaxis", .reports, "Change the order of report cards.")
        case .settings:
            ("Settings", "gearshape.fill", .settings, "Open Actualist settings.")
        case .appearance:
            ("Appearance", "paintbrush.fill", .settings, "Choose your theme and display preferences.")
        case .privacy:
            ("Privacy & Alerts", "hand.raised.fill", .settings, "Manage privacy and notification preferences.")
        case .connection:
            ("Connection & Sync", "antenna.radiowaves.left.and.right", .settings, "Manage your server connection and sync settings.")
        case .budgetData:
            ("Budget & Data", "folder.fill", .settings, "Manage your selected budget and account preferences.")
        case .advanced:
            ("Advanced", "wrench.and.screwdriver.fill", .settings, "Open experimental features and advanced settings.")
        case .support:
            ("Support", "questionmark.circle.fill", .settings, "Find help and diagnostic information.")
        }
    }
}

struct WidgetQuickActions: Equatable, Sendable {
    static let capacity = 4
    static let defaults: [WidgetQuickAction] = [.addExpense, .budget, .spending, .accounts]
    let actions: [WidgetQuickAction]

    init(_ actions: [WidgetQuickAction] = Self.defaults) {
        var seen = Set<WidgetQuickAction>()
        self.actions = Array((actions + Self.defaults).filter { seen.insert($0).inserted }.prefix(Self.capacity))
    }
}
