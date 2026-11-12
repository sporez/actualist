import Foundation

struct WidgetMoney: Codable, Equatable, Sendable {
    let minorUnits: Int
    let formatted: String

    /// USD sample money for gallery placeholders; the extension has no budget currency.
    static func placeholder(_ minorUnits: Int) -> WidgetMoney {
        WidgetMoney(minorUnits: minorUnits, formatted: (Double(minorUnits) / 100).formatted(.currency(code: "USD")))
    }

    var tone: WidgetAmountTone {
        minorUnits < 0 ? .negative : (minorUnits == 0 ? .zero : .positive)
    }

    /// Names a category's balance, which a bare amount leaves ambiguous.
    var availabilityTitle: String { minorUnits < 0 ? "Overspent" : "Available" }
}

struct WidgetAccountSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let group: String
    let isClosed: Bool
    let balance: WidgetMoney?
}

struct WidgetAttentionSnapshot: Codable, Equatable, Sendable {
    let uncategorizedCount: Int
    let overspentCategoryIDs: [String]

    var issueCount: Int { uncategorizedCount + overspentCategoryIDs.count }

    var reviewText: String {
        switch issueCount {
        case 0: "All caught up"
        case 1: "1 budget item to review"
        default: "\(issueCount) budget items to review"
        }
    }

    var status: WidgetStatus {
        if !overspentCategoryIDs.isEmpty { return .negative }
        return uncategorizedCount > 0 ? .caution : .positive
    }

    /// Where a whole-widget tap goes, for sizes that cannot host separate links.
    var primaryAction: WidgetQuickAction {
        overspentCategoryIDs.isEmpty && uncategorizedCount > 0 ? .uncategorized : .budget
    }
}

struct WidgetMonthOverviewSnapshot: Codable, Equatable, Sendable {
    let income: WidgetMoney
    let spent: WidgetMoney
    let toBudget: WidgetMoney?
    let budgeted: WidgetMoney
    let available: WidgetMoney
    var summary: WidgetSummaryMetric?

    // Version 2 envelope snapshots predate typed summaries.
    var displayedSummary: WidgetSummaryMetric? {
        summary ?? toBudget.map { WidgetSummaryMetric(kind: .toBudget, amount: $0) }
    }
    var balanceLabel: String { toBudget == nil ? "Balance" : "Available" }
}

struct WidgetSummaryMetric: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case toBudget, projectedSavings, saved, overspent

        var title: String {
            switch self {
            case .toBudget: "To Budget"
            case .projectedSavings: "Projected Savings"
            case .saved: "Saved"
            case .overspent: "Overspent"
            }
        }
    }
    let kind: Kind
    let amount: WidgetMoney
}

struct WidgetTransactionSnapshot: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let accountID: String
    let accountName: String
    let payee: String
    let date: String
    let amount: WidgetMoney?

    /// Today, Yesterday, or a short date. Stored text that is not a date is shown as is.
    func dayText(now: Date, calendar: Calendar) -> String {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return date
        }
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .autoupdatingCurrent
        return day.formatted(style)
    }
}

struct WidgetNetWorthPoint: Codable, Equatable, Sendable, Identifiable {
    let date: Date
    let amount: WidgetMoney
    var id: Date { date }
}

struct WidgetNetWorthSnapshot: Codable, Equatable, Sendable {
    let balance: WidgetMoney
    let change: WidgetMoney
    let period: String
    let points: [WidgetNetWorthPoint]

    var changeText: String {
        change.minorUnits > 0 ? "+\(change.formatted)" : change.formatted
    }

    /// Keeps the line off the plot's edges, including for a flat history.
    var chartDomain: ClosedRange<Int> {
        let amounts = points.map(\.amount.minorUnits)
        let low = amounts.min() ?? 0
        let high = amounts.max() ?? 0
        let span = max(high - low, 100)
        return (low - span / 3)...(high + span / 8)
    }
}
