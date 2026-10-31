import SwiftUI
import WidgetKit

enum WidgetSizeSupport {
    static var home: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        // The iOS 26 SDK declares this case unavailable on iOS.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        #endif
        return families
    }

    static func size(_ family: WidgetFamily) -> WidgetFamilySize {
        switch family {
        case .systemSmall, .accessoryInline, .accessoryRectangular, .accessoryCircular: return .small
        case .systemMedium: return .medium
        case .systemLarge: return .large
        case .systemExtraLarge: return .extraLarge
        default: return .extraLarge
        }
    }

    static func isAccessory(_ family: WidgetFamily) -> Bool {
        [.accessoryInline, .accessoryRectangular, .accessoryCircular].contains(family)
    }
}

struct WidgetEmptyView: View {
    @Environment(\.widgetPalette) private var palette
    let title: String
    var detail = "Open Actualist to refresh this widget."
    var symbol = "arrow.clockwise"
    /// For widgets that disable the system content margins.
    var margin: CGFloat = 0
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).widgetAccentable()
            Text(title).font(.headline)
            if !WidgetSizeSupport.isAccessory(family) {
                Text(detail).font(.caption).foregroundStyle(palette.secondaryText).multilineTextAlignment(.center)
            }
        }
        .padding(WidgetSizeSupport.isAccessory(family) ? 0 : margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetBalanceItem: Identifiable {
    let id: String
    let name: String
    let amount: WidgetMoney?
    let destination: URL
}

/// Shared layout for Category and Account Balances. Only categories report a
/// status: a negative account balance, such as a credit card, is normal.
struct WidgetBalanceListView: View {
    enum Style {
        case status
        case plain
    }

    @Environment(\.widgetPalette) private var palette
    let items: [WidgetBalanceItem]
    var style = Style.status
    var margin = WidgetPlateMetrics.contentMargin
    var singleColumn = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let item = visibleItems.first, WidgetSizeSupport.size(family) == .small {
                single(item)
            } else if family == .systemExtraLarge && !singleColumn {
                HStack(alignment: .top, spacing: 24) {
                    column(Array(visibleItems.prefix(columnLimit)))
                    column(Array(visibleItems.dropFirst(columnLimit)))
                }
                .padding(margin)
            } else {
                column(visibleItems)
                    .padding(margin)
            }
        }
        .widgetURL(items.first?.destination)
        .privacySensitive()
    }

    /// Splits evenly, so a short list does not stretch across the whole width.
    private var columnLimit: Int { (visibleItems.count + 1) / 2 }
    private var visibleItems: [WidgetBalanceItem] {
        let limit: Int
        if typeSize.isAccessibilitySize {
            limit = family == .systemMedium ? 2 : (WidgetSizeSupport.size(family) == .extraLarge ? 8 : 4)
        } else {
            limit = WidgetCategoryBalanceCapacity.maximum(for: WidgetSizeSupport.size(family))
        }
        return Array(items.prefix(limit))
    }

    @ViewBuilder private func single(_ item: WidgetBalanceItem) -> some View {
        if family == .accessoryInline {
            Text("\(item.name): \(item.amount?.formatted ?? "Unavailable")")
        } else if family == .systemSmall {
            switch style {
            case .status:
                let status = WidgetStatus(item.amount?.tone ?? .zero)
                WidgetStatusPlate(status: status) {
                    hero(item, amountColor: palette.plateForeground(status))
                }
                .padding(WidgetPlateMetrics.inset)
            case .plain:
                hero(item, amountColor: plainColor(item))
                    .padding(WidgetPlateMetrics.contentMargin)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1).minimumScaleFactor(0.65)
                Text(item.amount?.formatted ?? "Unavailable")
                    .font(.headline).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func hero(_ item: WidgetBalanceItem, amountColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.name).font(.headline)
                .lineLimit(typeSize.isAccessibilitySize ? 1 : 2).minimumScaleFactor(0.65)
            Spacer(minLength: 2)
            if !typeSize.isAccessibilitySize {
                Text(heroTitle(item)).font(.caption.weight(.semibold)).opacity(0.75).lineLimit(1)
            }
            Text(item.amount?.formatted ?? "Unavailable").font(.widgetHero(56)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.35)
                .foregroundStyle(amountColor)
                .widgetAccentable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func heroTitle(_ item: WidgetBalanceItem) -> String {
        switch style {
        case .status: item.amount?.availabilityTitle ?? "Available"
        case .plain: "Balance"
        }
    }

    private func plainColor(_ item: WidgetBalanceItem) -> Color {
        item.amount?.tone == .negative ? palette.danger : palette.primaryText
    }

    private func column(_ rows: [WidgetBalanceItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { item in
                Link(destination: item.destination) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        amount(item)
                    }
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 72)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(item.name), \(item.amount?.formatted ?? "Balance unavailable")")
                }
                .buttonStyle(.plain)
                if item.id != rows.last?.id { Divider() }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func amount(_ item: WidgetBalanceItem) -> some View {
        let text = Text(item.amount?.formatted ?? "—")
            .font(.subheadline.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        switch style {
        case .status:
            let status = WidgetStatus(item.amount?.tone ?? .zero)
            text
                .padding(.horizontal, 9).padding(.vertical, 4)
                .foregroundStyle(palette.plateForeground(status))
                .background(palette.plateFill(status) ?? palette.track, in: Capsule())
        case .plain:
            text.foregroundStyle(plainColor(item))
        }
    }
}

/// Appears only once the data is from an earlier day, so a fresh widget stays quiet.
struct WidgetStaleLabel: View {
    @Environment(\.widgetPalette) private var palette
    let updatedAt: Date
    let now: Date

    var body: some View {
        if !WidgetMonthID.gregorianCalendar().isDate(updatedAt, inSameDayAs: now) {
            Text("Updated \(updatedAt, format: .dateTime.month(.abbreviated).day())")
                .font(.caption2).foregroundStyle(palette.secondaryText)
        }
    }
}
