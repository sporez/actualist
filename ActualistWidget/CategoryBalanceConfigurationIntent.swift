import AppIntents
import WidgetKit

struct CategoryBalanceConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Category Balances"
    static let description = IntentDescription("Choose categories in display order. Larger widgets show more balances.")

    // Keep the ordered selection when resizing; the layout applies its row limit.
    @Parameter(title: "Categories", size: .init(min: 1, max: 16))
    var categories: [WidgetCategoryEntity]?
}
