import AppIntents
import WidgetKit

struct CategoryBalanceConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Category Balances"
    static let description = IntentDescription(
        "Choose categories in display order. Medium shows up to 3; large shows up to 8."
    )

    // AppIntents requires literal bounds here. These mirror
    // WidgetCategoryBalanceCapacity, which owns runtime row limits.
    @Parameter(
        title: "Categories",
        size: [
            .systemMedium: .init(min: 1, max: 3),
            .systemLarge: .init(min: 1, max: 8)
        ]
    )
    var categories: [WidgetCategoryEntity]?
}
