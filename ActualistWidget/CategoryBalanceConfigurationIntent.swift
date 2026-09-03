import AppIntents
import WidgetKit

struct CategoryBalanceConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Category Balances"
    static let description = IntentDescription(
        "Choose categories in display order. Medium shows 3; large shows 8."
    )

    @Parameter(title: "Categories")
    var categories: [WidgetCategoryEntity]?
}
