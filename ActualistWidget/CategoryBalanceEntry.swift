import Foundation
import WidgetKit

struct CategoryBalanceEntry: TimelineEntry {
    var date: Date
    var state: WidgetCategoryBalanceState
    var rows: [WidgetCategoryBalanceRow]
    var budgetName: String
    var theme: ActualistThemeOption = .actualPurple

    static let placeholder = CategoryBalanceEntry(
        date: Date(),
        state: .placeholder,
        rows: [
            ("groceries", "Groceries", 32_500), ("dining", "Dining Out", 8_425), ("fuel", "Fuel", 0),
            ("rent", "Rent", 150_000), ("fun", "Fun Money", -2_150), ("travel", "Travel", 64_000),
            ("gifts", "Gifts", 12_000), ("home", "Home", 27_500)
        ].map { id, name, amount in
            func money(_ value: Int) -> WidgetMoney {
                WidgetMoney(minorUnits: value, formatted: (Double(value) / 100).formatted(.currency(code: "USD")))
            }
            return WidgetCategoryBalanceRow(
                id: id, name: name,
                formattedAvailable: money(amount).formatted,
                availableMinorUnits: amount, month: "2026-07",
                spending: WidgetCategorySpending(spent: money(40_000), total: money(40_000 + amount))
            )
        },
        budgetName: "Sample Budget"
    )
}
