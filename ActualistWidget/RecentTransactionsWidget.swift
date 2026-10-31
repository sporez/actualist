import SwiftUI
import WidgetKit

struct RecentTransactionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.recentTransactions, provider: BudgetSummaryTimelineProvider()) {
            RecentTransactionsWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Recent Transactions")
        .description("Your latest transactions across accounts. Tap a transaction to open its account.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryRectangular])
    }
}

struct RecentTransactionsWidgetView: View {
    @Environment(\.widgetPalette) private var palette
    let entry: BudgetSummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        WidgetSummaryShell(snapshot: entry.snapshot, now: entry.date, destination: destination) { snapshot in
            if let transactions = snapshot.recentTransactions {
                if transactions.isEmpty {
                    WidgetEmptyView(title: "No Transactions", detail: "Your latest activity will appear here.", symbol: "banknote")
                } else if family == .accessoryRectangular, let first = transactions.first {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(first.payee).font(.headline).lineLimit(1).minimumScaleFactor(0.65)
                        Text(first.amount?.formatted ?? "Unavailable").monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if family == .systemSmall, let first = transactions.first {
                    latest(first)
                } else if family == .systemExtraLarge {
                    HStack(alignment: .top, spacing: 24) {
                        rows(Array(transactions.prefix(typeSize.isAccessibilitySize ? 3 : 6)))
                        rows(Array(transactions.dropFirst(typeSize.isAccessibilitySize ? 3 : 6).prefix(typeSize.isAccessibilitySize ? 3 : 6)))
                    }
                } else {
                    rows(Array(transactions.prefix(rowCount)))
                }
            } else {
                WidgetEmptyView(title: "Nothing to Show Yet")
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

    private func dayText(_ transaction: WidgetTransactionSnapshot) -> String {
        transaction.dayText(now: entry.date, calendar: WidgetMonthID.gregorianCalendar())
    }

    /// Green marks money coming in; spending stays plain so income stands out.
    private func amountColor(_ amount: WidgetMoney?) -> Color {
        amount?.tone == .positive ? palette.positive : palette.primaryText
    }

    private func latest(_ transaction: WidgetTransactionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dayText(transaction)).font(.caption.weight(.semibold)).foregroundStyle(palette.secondaryText)
            Spacer(minLength: 4)
            Text(transaction.payee).font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 1 : 2)
                .minimumScaleFactor(0.7)
            Text(transaction.amount?.formatted ?? "Unavailable").font(.widgetHero(28)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(amountColor(transaction.amount))
            if !typeSize.isAccessibilitySize {
                Text(transaction.accountName).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func rows(_ transactions: [WidgetTransactionSnapshot]) -> some View {
        VStack(spacing: 0) {
            ForEach(transactions) { transaction in
                Link(destination: WidgetDeepLink.url(.account(id: transaction.accountID))) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(transaction.payee).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(transaction.accountName).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(transaction.amount?.formatted ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(amountColor(transaction.amount))
                            Text(dayText(transaction)).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                        }
                    }
                    .foregroundStyle(palette.primaryText)
                    .frame(maxHeight: 64)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                if transaction.id != transactions.last?.id { Divider() }
            }
            Spacer(minLength: 0)
        }
    }
}
