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
            WidgetCategoryBalanceRow(
                id: id, name: name,
                formattedAvailable: (Double(amount) / 100).formatted(.currency(code: "USD")),
                availableMinorUnits: amount, month: "2026-07"
            )
        },
        budgetName: "Sample Budget"
    )
}
