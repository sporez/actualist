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
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).widgetAccentable()
            Text(title).font(.headline)
            if !WidgetSizeSupport.isAccessory(family) {
                Text(detail).font(.caption).foregroundStyle(palette.secondaryText).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WidgetBalanceItem: Identifiable {
    let id: String
    let name: String
    let amount: WidgetMoney?
    let destination: URL
}

/// Shared layout keeps Account Balances a visual clone of Category Balances.
struct WidgetBalanceListView: View {
    @Environment(\.widgetPalette) private var palette
    let title: String
    let items: [WidgetBalanceItem]
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let item = visibleItems.first, WidgetSizeSupport.size(family) == .small {
                single(item)
            } else if family == .systemExtraLarge {
                HStack(alignment: .top, spacing: 24) {
                    column(Array(visibleItems.prefix(columnLimit)))
                    column(Array(visibleItems.dropFirst(columnLimit)))
                }
            } else {
                column(visibleItems)
            }
        }
        .widgetURL(items.first?.destination)
        .privacySensitive()
    }

    private var columnLimit: Int { typeSize.isAccessibilitySize ? 4 : 8 }
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
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.name).font(.headline).lineLimit(typeSize.isAccessibilitySize ? 1 : (family == .systemSmall ? 2 : 1)).minimumScaleFactor(0.65)
                Text(item.amount?.formatted ?? "Unavailable")
                    .font(family == .systemSmall ? .title2.bold() : .headline)
                    .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    .foregroundStyle(palette.color(item.amount?.tone ?? .zero))
                if family == .systemSmall && !typeSize.isAccessibilitySize {
                    Text(title).font(.caption).foregroundStyle(palette.secondaryText)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func column(_ rows: [WidgetBalanceItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { item in
                Link(destination: item.destination) {
                    HStack(spacing: 8) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(item.amount?.formatted ?? "—")
                            .font(.subheadline.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(palette.color(item.amount?.tone ?? .zero).opacity(0.18), in: Capsule())
                    }
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 34)
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
}

struct WidgetUpdatedLabel: View {
    @Environment(\.widgetPalette) private var palette
    let date: Date
    var body: some View {
        Text("Updated \(date, style: .date)").font(.caption2).foregroundStyle(palette.secondaryText)
    }
}
