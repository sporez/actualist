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
    let snapshot: WidgetSnapshot?
    let now: Date
    let destination: URL
    /// For widgets that disable the system content margins.
    var margin: CGFloat = 0
    @ViewBuilder let content: (WidgetSnapshot) -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    content(snapshot)
                    if WidgetSizeSupport.size(family) == .large || WidgetSizeSupport.size(family) == .extraLarge {
                        WidgetStaleLabel(updatedAt: snapshot.updatedAt, now: now)
                            .padding(.horizontal, margin)
                            .padding(.bottom, margin / 2)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet", margin: margin)
            }
        }
        .widgetURL(destination)
        .privacySensitive()
    }
}
