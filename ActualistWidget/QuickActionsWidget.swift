import SwiftUI
import WidgetKit

struct QuickActionsEntry: TimelineEntry {
    let date: Date
    let configuration: WidgetQuickActions
    var theme: ActualistThemeOption = .actualPurple
}

struct QuickActionsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date(), configuration: WidgetQuickActions(), theme: WidgetThemeStore.live.load())
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
            theme: WidgetThemeStore.live.load()
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
            QuickActionsWidgetView(entry: entry).widgetTheme(entry.theme)
        }
        .configurationDisplayName("Quick Actions")
        .description("Open your favorite actions. Choose four and set their order in Edit Widget.")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickActionsWidgetView: View {
    let entry: QuickActionsEntry
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ACTUALIST")
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.secondaryText)
            QuickActionsRow(actions: entry.configuration.actions)
        }
    }
}

#Preview(as: .systemMedium) {
    QuickActionsWidget()
} timeline: {
    QuickActionsEntry(date: .now, configuration: WidgetQuickActions())
    QuickActionsEntry(date: .now, configuration: WidgetQuickActions([.uncategorized, .bankSync, .templates, .addIncome]))
}
