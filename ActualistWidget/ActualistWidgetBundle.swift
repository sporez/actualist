import SwiftUI
import WidgetKit

@main
struct ActualistWidgetBundle: WidgetBundle {
    var body: some Widget {
        CategoryBalanceWidget()
        QuickActionsWidget()
        AccountBalancesWidget()
        NeedsAttentionWidget()
        MonthOverviewWidget()
        RecentTransactionsWidget()
        NetWorthWidget()
    }
}
