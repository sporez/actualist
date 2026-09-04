import SwiftUI
import WidgetKit

struct NeedsAttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.needsAttention, provider: BudgetSummaryTimelineProvider()) {
            NeedsAttentionWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Needs Attention")
        .description("Overspent categories and transactions waiting for a category.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular, .accessoryCircular])
    }
}

struct NeedsAttentionWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(title: "Needs Attention", snapshot: entry.snapshot, destination: WidgetDeepLink.url(.quickAction(.budget))) { snapshot in
            if let attention = snapshot.attention {
                if family == .accessoryInline {
                    Text("\(attention.issueCount) budget items to review")
                } else if family == .accessoryCircular {
                    VStack { Image(systemName: "exclamationmark.circle"); Text("\(attention.issueCount)").bold() }
                } else if family == .systemSmall && typeSize.isAccessibilitySize {
                    Text("\(attention.issueCount)").font(.largeTitle.bold()).minimumScaleFactor(0.6).lineLimit(1)
                    Text(attention.issueCount == 0 ? "All caught up" : "To review").font(.caption).lineLimit(1).minimumScaleFactor(0.7)
                } else if attention.issueCount == 0 {
                    WidgetEmptyView(title: "All caught up", detail: "No overspent categories or uncategorized transactions.", symbol: "checkmark.circle")
                } else {
                    counts(attention)
                    if WidgetSizeSupport.size(family) == .large || WidgetSizeSupport.size(family) == .extraLarge {
                        Text("Overspent categories").font(.caption).foregroundStyle(palette.secondaryText)
                        WidgetBalanceListView(title: "Overspent", items: overspentItems(snapshot, attention: attention))
                    }
                }
            } else {
                WidgetEmptyView(title: "Refresh attention")
            }
        }
    }

    private func counts(_ attention: WidgetAttentionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: WidgetDeepLink.url(.quickAction(.budget))) {
                Label("\(attention.overspentCategoryIDs.count) overspent", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(palette.danger)
            }.buttonStyle(.plain)
            Link(destination: WidgetDeepLink.url(.quickAction(.uncategorized))) {
                Label("\(attention.uncategorizedCount) uncategorized", systemImage: "tray.fill")
                    .foregroundStyle(palette.primaryText)
            }.buttonStyle(.plain)
        }.font(.subheadline.weight(.semibold)).widgetAccentable()
    }

    private func overspentItems(_ snapshot: WidgetSnapshot, attention: WidgetAttentionSnapshot) -> [WidgetBalanceItem] {
        WidgetCategoryBalanceProjection.rows(
            selectedIDs: attention.overspentCategoryIDs, snapshot: snapshot,
            limit: typeSize.isAccessibilitySize ? (family == .systemLarge ? 1 : 3) : WidgetCategoryBalanceCapacity.maximum(for: WidgetSizeSupport.size(family)) - 2
        ).map {
            WidgetBalanceItem(id: $0.id, name: $0.name,
                amount: WidgetMoney(minorUnits: $0.availableMinorUnits, formatted: $0.formattedAvailable),
                destination: WidgetDeepLink.url(.category(id: $0.id, month: $0.month)))
        }
    }
}
