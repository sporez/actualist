import SwiftUI
import WidgetKit

struct QuickActionsEntry: TimelineEntry {
    let date: Date
    let configuration: WidgetQuickActions
    var appearance: ActualistAppearance = .fixed(.actualPurple)
}

struct QuickActionsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date(), configuration: WidgetQuickActions(), appearance: WidgetThemeStore.live.load())
    }

    func snapshot(for configuration: QuickActionsConfigurationIntent, in context: Context) async -> QuickActionsEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: QuickActionsConfigurationIntent, in context: Context) async -> Timeline<QuickActionsEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: QuickActionsConfigurationIntent) -> QuickActionsEntry {
        QuickActionsEntry(
            date: Date(),
            configuration: WidgetQuickActions(configuration.actions?.map(\.action) ?? []),
            appearance: WidgetThemeStore.live.load()
        )
    }
}

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WidgetKind.quickActions,
            intent: QuickActionsConfigurationIntent.self,
            provider: QuickActionsTimelineProvider()
        ) { entry in
            QuickActionsWidgetView(entry: entry).widgetTheme(entry.appearance)
        }
        .configurationDisplayName("Quick Actions")
        .description("Open your favorite actions. Choose four and set their order in Edit Widget.")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickActionsWidgetView: View {
    let entry: QuickActionsEntry

    var body: some View {
        QuickActionsRow(actions: entry.configuration.actions)
            .frame(maxHeight: .infinity)
    }
}

#Preview(as: .systemMedium) {
    QuickActionsWidget()
} timeline: {
    QuickActionsEntry(date: .now, configuration: WidgetQuickActions())
    QuickActionsEntry(date: .now, configuration: WidgetQuickActions([.uncategorized, .bankSync, .templates, .addIncome]))
}
