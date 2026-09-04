import SwiftUI
import WidgetKit

struct RecentTransactionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.recentTransactions, provider: BudgetSummaryTimelineProvider()) {
            RecentTransactionsWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Recent Transactions")
        .description("Your latest transactions across accounts. Tap a row to open its account.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryRectangular])
    }
}

struct RecentTransactionsWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(title: family == .systemSmall ? "Latest Transaction" : "Recent Transactions", snapshot: entry.snapshot, destination: destination) { snapshot in
            if let transactions = snapshot.recentTransactions {
                if transactions.isEmpty {
                    WidgetEmptyView(title: "No transactions", detail: "Your latest activity will appear here.", symbol: "banknote")
                } else if WidgetSizeSupport.size(family) == .small, let first = transactions.first {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(first.payee).font(.headline).lineLimit(1).minimumScaleFactor(0.65)
                        Text(first.amount?.formatted ?? "Unavailable").font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        if !typeSize.isAccessibilitySize {
                            Text(first.accountName).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                    }
                } else if family == .systemExtraLarge {
                    HStack(alignment: .top, spacing: 24) {
                        rows(Array(transactions.prefix(typeSize.isAccessibilitySize ? 3 : 6)))
                        rows(Array(transactions.dropFirst(typeSize.isAccessibilitySize ? 3 : 6).prefix(typeSize.isAccessibilitySize ? 3 : 6)))
                    }
                } else {
                    rows(Array(transactions.prefix(rowCount)))
                }
            } else {
                WidgetEmptyView(title: "Refresh transactions")
            }
        }
    }
    private var destination: URL {
        if WidgetSizeSupport.size(family) == .small, let first = entry.snapshot?.recentTransactions?.first {
            return WidgetDeepLink.url(.account(id: first.accountID))
        }
        return WidgetDeepLink.url(.quickAction(.spending))
    }
    private var rowCount: Int {
        switch WidgetSizeSupport.size(family) {
        case .small: 1
        case .medium: typeSize.isAccessibilitySize ? 1 : 3
        case .large: typeSize.isAccessibilitySize ? 3 : 6
        case .extraLarge: typeSize.isAccessibilitySize ? 6 : 12
        }
    }
    private func rows(_ transactions: [WidgetTransactionSnapshot]) -> some View {
        VStack(spacing: 6) {
            ForEach(transactions) { transaction in
                Link(destination: WidgetDeepLink.url(.account(id: transaction.accountID))) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.payee).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("\(transaction.date) · \(transaction.accountName)")
                                .font(.caption2).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 2)
                        Text(transaction.amount?.formatted ?? "—").font(.caption.bold()).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.foregroundStyle(palette.primaryText).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if transaction.id != transactions.last?.id { Divider() }
            }
            Spacer(minLength: 0)
        }
    }
}
