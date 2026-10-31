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
        .contentMarginsDisabled()
    }
}

struct NeedsAttentionWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(snapshot: entry.snapshot, now: entry.date, destination: destination, margin: WidgetPlateMetrics.contentMargin) { snapshot in
            if let attention = snapshot.attention {
                content(snapshot, attention)
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet", margin: WidgetPlateMetrics.contentMargin)
            }
        }
    }

    private var destination: URL {
        WidgetDeepLink.url(.quickAction(entry.snapshot?.attention?.primaryAction ?? .budget))
    }

    private var canHostLinks: Bool { family != .systemSmall }

    private var isTall: Bool {
        family == .systemLarge || WidgetSizeSupport.size(family) == .extraLarge
    }

    @ViewBuilder private func content(_ snapshot: WidgetSnapshot, _ attention: WidgetAttentionSnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Text(attention.reviewText)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if attention.issueCount == 0 {
                    Image(systemName: "checkmark").font(.title3.weight(.bold))
                } else {
                    VStack(spacing: 0) {
                        Image(systemName: "exclamationmark.circle").font(.caption2.weight(.semibold))
                        Text("\(attention.issueCount)").font(.widgetHero(20)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                }
            }
        case .accessoryRectangular:
            if attention.issueCount == 0 {
                Label("All Caught Up", systemImage: "checkmark.circle")
            } else {
                issues(attention)
            }
        default:
            if attention.issueCount == 0 {
                caughtUp
            } else if family == .systemSmall && typeSize.isAccessibilitySize {
                plate(attention)
                    .padding(WidgetPlateMetrics.inset)
            } else {
                WidgetPlateLayout {
                    plate(attention)
                } details: {
                    VStack(spacing: 0) {
                        issues(attention)
                        if isTall && !attention.overspentCategoryIDs.isEmpty {
                            WidgetBalanceListView(
                                items: overspentItems(snapshot, attention: attention), margin: 0, singleColumn: true
                            )
                        }
                    }
                }
            }
        }
    }

    private var caughtUp: some View {
        WidgetStatusPlate(status: .positive) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44, weight: .semibold)).widgetAccentable()
                Spacer(minLength: 4)
                Text("All Caught Up").font(.widgetHero(family == .systemSmall ? 26 : 34))
                    .lineLimit(2).minimumScaleFactor(0.6)
                if family != .systemSmall {
                    Text("No overspent categories or uncategorized transactions.")
                        .font(.caption.weight(.medium)).opacity(0.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(WidgetPlateMetrics.inset)
    }

    private var heroFont: Font {
        switch family {
        case .systemSmall: .widgetHero(40)
        case .systemMedium: .widgetHero(68)
        case .systemLarge: .widgetHero(76)
        default: .widgetHero(110)
        }
    }

    private func plate(_ attention: WidgetAttentionSnapshot) -> some View {
        WidgetStatusPlate(status: attention.status) {
            VStack(alignment: .leading, spacing: 0) {
                if family != .systemSmall {
                    Image(systemName: "exclamationmark.circle.fill").font(.title3.weight(.semibold))
                    Spacer(minLength: 4)
                }
                Text("\(attention.issueCount)").font(heroFont).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .widgetAccentable()
                Text("To Review").font(.caption.weight(.semibold)).opacity(0.75)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// Each warning is gated by its own count; a positive total does not imply both.
    private func issues(_ attention: WidgetAttentionSnapshot) -> some View {
        VStack(spacing: 0) {
            if !attention.overspentCategoryIDs.isEmpty {
                issue(
                    "\(attention.overspentCategoryIDs.count) overspent",
                    symbol: "exclamationmark.circle.fill", color: palette.danger, action: .budget
                )
            }
            if !attention.overspentCategoryIDs.isEmpty && attention.uncategorizedCount > 0 {
                Divider()
            }
            if attention.uncategorizedCount > 0 {
                issue(
                    "\(attention.uncategorizedCount) uncategorized",
                    symbol: "tray.fill", color: palette.warning, action: .uncategorized
                )
            }
        }
        .widgetAccentable()
    }

    @ViewBuilder private func issue(
        _ text: String, symbol: String, color: Color, action: WidgetQuickAction
    ) -> some View {
        let row = HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if canHostLinks && !WidgetSizeSupport.isAccessory(family) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(palette.secondaryText)
            }
        }
        .font(family == .systemSmall ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(palette.primaryText)
        .frame(minHeight: isTall ? 40 : nil)
        .frame(maxHeight: isTall ? nil : .infinity)
        .contentShape(Rectangle())

        if canHostLinks {
            Link(destination: WidgetDeepLink.url(.quickAction(action))) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }

    private var overspentLimit: Int {
        if typeSize.isAccessibilitySize { return family == .systemLarge ? 1 : 3 }
        return family == .systemLarge ? 3 : 6
    }

    private func overspentItems(_ snapshot: WidgetSnapshot, attention: WidgetAttentionSnapshot) -> [WidgetBalanceItem] {
        WidgetCategoryBalanceProjection.rows(
            selectedIDs: attention.overspentCategoryIDs, snapshot: snapshot, limit: overspentLimit
        ).map {
            WidgetBalanceItem(id: $0.id, name: $0.name,
                amount: WidgetMoney(minorUnits: $0.availableMinorUnits, formatted: $0.formattedAvailable),
                destination: WidgetDeepLink.url(.category(id: $0.id, month: $0.month)))
        }
    }
}
