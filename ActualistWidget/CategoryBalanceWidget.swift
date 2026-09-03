import SwiftUI
import WidgetKit

struct CategoryBalanceWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WidgetKind.categoryBalance,
            intent: CategoryBalanceConfigurationIntent.self,
            provider: CategoryBalanceTimelineProvider()
        ) { entry in
            CategoryBalanceWidgetView(entry: entry)
        }
        .configurationDisplayName("Category Balances")
        .description("Keep an eye on the categories that matter most.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
