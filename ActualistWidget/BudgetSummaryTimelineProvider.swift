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
        let days = WidgetMonthID.dailyBoundaries(after: value.date).map {
            BudgetSummaryEntry(date: $0, snapshot: value.snapshot, theme: value.theme)
        }
        completion(Timeline(entries: [value] + days, policy: .after(WidgetMonthID.nextBoundary(after: value.date))))
    }
    private func entry() -> BudgetSummaryEntry {
        BudgetSummaryEntry(date: .now, snapshot: WidgetFinancialProjection.currentSnapshot(WidgetSnapshotStore.live.load()), theme: WidgetThemeStore.live.load())
    }
}

struct WidgetSummaryShell<Content: View>: View {
    @Environment(\.widgetPalette) private var palette
    /// Nil gives the content the whole widget, without the header and Updated line.
    var title: String?
    let snapshot: WidgetSnapshot?
    let destination: URL
    @ViewBuilder let content: (WidgetSnapshot) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: title == nil ? 0 : 8) {
                    if let title, !WidgetSizeSupport.isAccessory(family) {
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    content(snapshot)
                    if title != nil, WidgetSizeSupport.size(family) == .large || WidgetSizeSupport.size(family) == .extraLarge {
                        WidgetUpdatedLabel(date: snapshot.updatedAt)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet", margin: title == nil ? 16 : 0)
            }
        }
        .widgetURL(destination)
        .privacySensitive()
    }
}
