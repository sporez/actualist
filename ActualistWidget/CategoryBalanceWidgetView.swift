import SwiftUI
import WidgetKit

struct CategoryBalanceWidgetView: View {
    let entry: CategoryBalanceEntry
    var body: some View {
        Group {
            switch entry.state {
            case .placeholder, .ready:
                WidgetBalanceListView(title: "Category Balances", items: entry.rows.map {
                    WidgetBalanceItem(
                        id: $0.id, name: $0.name,
                        amount: WidgetMoney(minorUnits: $0.availableMinorUnits, formatted: $0.formattedAvailable),
                        destination: WidgetDeepLink.url(.category(id: $0.id, month: $0.month))
                    )
                }).redacted(reason: entry.state == .placeholder ? .placeholder : [])
            case .needsCategories:
                WidgetEmptyView(title: "Choose categories", detail: "Edit this widget to select your categories.", symbol: "list.bullet.rectangle.portrait")
            case .needsApp:
                WidgetEmptyView(title: "Open Actualist")
            case .categoriesUnavailable:
                WidgetEmptyView(title: "Update categories", detail: "Choose categories from your current budget.")
            }
        }
        .accessibilityLabel(entry.budgetName.isEmpty ? "Category balances" : "Category balances for \(entry.budgetName)")
    }
}
