import Foundation

/// Pure grouping of transactions into date sections for display.
///
/// Computed off the data set (on change), not per view-render, and uses cached `DateFormatter`s
/// — both expensive to do repeatedly for accounts with many transactions.
enum TransactionGrouping {
    static func grouped(_ transactions: [ActualTransaction]) -> [TransactionDateGroup] {
        let groups = Dictionary(grouping: transactions, by: { $0.date })
        return groups.keys.sorted(by: >).map { date in
            TransactionDateGroup(date: date, title: displayTitle(date), transactions: groups[date] ?? [])
        }
    }

    static func displayTitle(_ value: String) -> String {
        guard let date = inputFormatter.date(from: value) else {
            return value
        }
        return outputFormatter.string(from: date)
    }

    private static let inputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let outputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        return formatter
    }()
}
