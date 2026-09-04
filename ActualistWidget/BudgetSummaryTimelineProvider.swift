import SwiftUI
import WidgetKit

struct BudgetSummaryEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var theme: ActualistThemeOption = .actualPurple
}

struct BudgetSummaryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BudgetSummaryEntry {
        BudgetSummaryEntry(date: .now, snapshot: WidgetPreviewData.snapshot, theme: WidgetThemeStore.live.load())
    }
    func getSnapshot(in context: Context, completion: @escaping (BudgetSummaryEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetSummaryEntry>) -> Void) {
        let value = entry()
        completion(Timeline(entries: [value], policy: .after(WidgetMonthID.nextBoundary(after: value.date))))
    }
    private func entry() -> BudgetSummaryEntry {
        BudgetSummaryEntry(date: .now, snapshot: WidgetFinancialProjection.currentSnapshot(WidgetSnapshotStore.live.load()), theme: WidgetThemeStore.live.load())
    }
}

struct WidgetSummaryShell<Content: View>: View {
    @Environment(\.widgetPalette) private var palette
    let title: String
    let snapshot: WidgetSnapshot?
    let destination: URL
    @ViewBuilder let content: (WidgetSnapshot) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    if !WidgetSizeSupport.isAccessory(family) {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    content(snapshot)
                    if WidgetSizeSupport.size(family) == .large || WidgetSizeSupport.size(family) == .extraLarge {
                        WidgetUpdatedLabel(date: snapshot.updatedAt)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WidgetEmptyView(title: "Open Actualist")
            }
        }
        .widgetURL(destination)
        .privacySensitive()
    }
}
