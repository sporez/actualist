import Foundation

enum BudgetMonthNavigationPresentation {
    static func title(
        for month: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> String {
        guard let month else {
            let dayID = ActualDateOnly.dayID(from: now, timeZone: timeZone)
            return ActualDateDisplay.monthYear(String(dayID.prefix(7)), locale: locale) ?? dayID
        }
        return ActualDateDisplay.monthYear(month, locale: locale) ?? month
    }

    static func pickerMonths(for loadedMonth: LoadedBudgetMonth) -> [String] {
        let loadedIDs = loadedMonth.availableMonths.compactMap(canonicalMonthID)
        let selectedIDs = [loadedMonth.selectedMonth, loadedMonth.month.month].compactMap(canonicalMonthID)
        return Array(Set(loadedIDs + selectedIDs)).sorted()
    }

    private static func canonicalMonthID(_ value: String) -> String? {
        YearMonth.canonicalID(value)
    }
}
