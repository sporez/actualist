import Foundation

enum WidgetAppGroup {
    static let identifier = "group.com.sporez.actualist"
}

enum WidgetKind {
    static let accountBalances = "AccountBalancesWidget"
    static let needsAttention = "NeedsAttentionWidget"
    static let monthOverview = "MonthOverviewWidget"
    static let recentTransactions = "RecentTransactionsWidget"
    static let netWorth = "NetWorthWidget"
    static let dataWidgets = [categoryBalance, accountBalances, needsAttention, monthOverview, recentTransactions, netWorth]
    static let quickActions = "QuickActionsWidget"
    static let categoryBalance = "CategoryBalanceWidget"
}
