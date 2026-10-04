import Foundation

enum BudgetMonthNavigationPresentation {
    static func title(for month: String?, now: Date = Date()) -> String {
        guard let month else {
            return title(for: now)
        }

        let input = DateFormatter()
        input.dateFormat = "yyyy-MM"
        guard let date = input.date(from: month) else {
            return month
        }
        return title(for: date)
    }

    static func pickerMonths(for loadedMonth: LoadedBudgetMonth) -> [String] {
        let loadedIDs = loadedMonth.availableMonths.compactMap(canonicalMonthID)
        let selectedIDs = [loadedMonth.selectedMonth, loadedMonth.month.month].compactMap(canonicalMonthID)
        return Array(Set(loadedIDs + selectedIDs)).sorted()
    }

    private static func title(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func canonicalMonthID(_ value: String) -> String? {
        YearMonth.canonicalID(value)
    }
}
