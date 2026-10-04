import Foundation

enum TransactionGrouping {
    static func grouped(_ transactions: [ActualTransaction]) -> [TransactionDateGroup] {
        let groups = Dictionary(grouping: transactions, by: { $0.date })
        return groups.keys.sorted(by: >).map { date in
            TransactionDateGroup(date: date, title: displayTitle(date), transactions: groups[date] ?? [])
        }
    }

    static func displayTitle(_ value: String, locale: Locale = .current) -> String {
        ActualDateDisplay.longDay(value, locale: locale) ?? value
    }
}
