import SwiftUI
import WidgetKit

struct CategoryBalanceWidgetView: View {
    let entry: CategoryBalanceEntry
    var body: some View {
        Group {
            switch entry.state {
            case .placeholder, .ready:
                WidgetBalanceListView(items: entry.rows.map {
                    WidgetBalanceItem(
                        id: $0.id, name: $0.name,
                        amount: WidgetMoney(minorUnits: $0.availableMinorUnits, formatted: $0.formattedAvailable),
                        destination: WidgetDeepLink.url(.category(id: $0.id, month: $0.month))
                    )
                }).redacted(reason: entry.state == .placeholder ? .placeholder : [])
            case .needsCategories:
                WidgetEmptyView(title: "Choose Categories", detail: "Edit this widget to select your categories.", symbol: "list.bullet.rectangle.portrait", margin: WidgetPlateMetrics.contentMargin)
            case .needsApp:
                WidgetEmptyView(title: "Nothing to Show Yet", margin: WidgetPlateMetrics.contentMargin)
            case .categoriesUnavailable:
                WidgetEmptyView(title: "Choose Categories Again", detail: "Edit this widget to choose categories from your current budget.", margin: WidgetPlateMetrics.contentMargin)
            }
        }
        .accessibilityLabel(entry.budgetName.isEmpty ? "Category balances" : "Category balances for \(entry.budgetName)")
    }
}
