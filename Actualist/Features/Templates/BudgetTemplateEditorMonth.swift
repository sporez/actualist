import Foundation

/// A Gregorian budget month at the UI boundary; the definition still stores YYYY-MM.
struct BudgetTemplateEditorMonth: Equatable {
    var year: Int
    var month: Int

    init?(storage: String) {
        guard let value = try? BudgetTemplateCalendar.parseMonth(storage) else { return nil }
        year = value / 100
        month = value % 100
    }

    init(now: Date) {
        let value = BudgetTemplateCalendar.currentMonthValue(now: now)
        year = value / 100
        month = value % 100
    }

    var storage: String { BudgetTemplateCalendar.monthID(year * 100 + month) }

    func title(locale: Locale) -> String {
        guard let date = try? BudgetTemplateCalendar.monthStartDate(year * 100 + month) else { return "Choose month" }
        return date.formatted(Date.FormatStyle(
            locale: locale, calendar: BudgetTemplateCalendar.gregorian
        ).month(.wide).year())
    }

    static func monthNames(locale: Locale) -> [String] {
        var calendar = BudgetTemplateCalendar.gregorian
        calendar.locale = locale
        return calendar.standaloneMonthSymbols
    }

    func supportedYears(now: Date) -> ClosedRange<Int> {
        let currentYear = BudgetTemplateCalendar.gregorian.component(.year, from: now)
        // Keep practical wheel travel, without excluding a previously authored month.
        return min(1900, year)...min(BudgetTemplateCalendar.year.upperBound, max(currentYear + 100, year))
    }
}
