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
            WidgetCategoryBalanceRow(
                id: "groceries",
                name: "Groceries",
                formattedAvailable: "$325.00",
                availableMinorUnits: 32_500,
                month: "2026-07"
            ),
            WidgetCategoryBalanceRow(
                id: "dining",
                name: "Dining Out",
                formattedAvailable: "$84.25",
                availableMinorUnits: 8_425,
                month: "2026-07"
            ),
            WidgetCategoryBalanceRow(
                id: "fuel",
                name: "Fuel",
                formattedAvailable: "$0.00",
                availableMinorUnits: 0,
                month: "2026-07"
            )
        ],
        budgetName: "Sample Budget"
    )
}
