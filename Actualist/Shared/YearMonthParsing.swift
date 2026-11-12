import Foundation

extension YearMonth {
    static let validYears = 1900...9999

    /// `YYYY-MM` text with no range validation. Packed-date callers and the
    /// date-component formatters depend on out-of-range values passing through
    /// unchanged; use `init?(year:month:)` when the values come from input.
    static func id(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// `YYYY-MM` text for a packed `YYYYMM` month value (unvalidated).
    static func id(packed monthValue: Int) -> String {
        id(year: monthValue / 100, month: monthValue % 100)
    }

    /// Packed `YYYYMM` from month (or day) text: every `-` is dropped and the
    /// rest read as one number, so `2026-01` is 202601 and text that is not
    /// digits is 0. Nothing is range-checked.
    static func packedUnchecked(_ id: String) -> Int {
        Int(PackedDate.compact(id)) ?? 0
    }

    /// Packed `YYYYMM` moved by `offset` months with no validation: a month
    /// outside 1...12 rolls over arithmetically and 0 stays 0. The template
    /// calendar's range-checked, throwing variant is
    /// `BudgetTemplateCalendar.shiftedMonth(_:by:)`.
    static func shiftedUnchecked(packed month: Int, by offset: Int) -> Int {
        let year = month / 100
        let monthNumber = month % 100
        let zeroBased = year * 12 + (monthNumber - 1) + offset
        let shiftedYear = zeroBased / 12
        let shiftedMonth = zeroBased % 12 + 1
        return shiftedYear * 100 + shiftedMonth
    }

    /// The packed month after `month` by incrementing, with no validation
    /// (202613 becomes 202614, where `shiftedUnchecked` would roll the year).
    static func nextUnchecked(packed month: Int) -> Int {
        let year = month / 100
        let monthNumber = month % 100
        if monthNumber == 12 {
            return (year + 1) * 100 + 1
        }
        return year * 100 + monthNumber + 1
    }

    /// `YYYY-MM` text for `id` moved by `months`, with no range validation: a
    /// month outside 1...12 rolls over the way a Gregorian calendar does
    /// ("2026-13" +0 is "2027-01"). Reports and Budget month swiping depend on
    /// that, so unparseable text (not two `-` pieces) comes back unchanged.
    /// `ignoringNonNumericParts` drops non-numeric pieces first, as Budget's
    /// swipe always did; Reports needs exactly two numeric pieces.
    static func shiftedID(_ id: String, by months: Int, ignoringNonNumericParts: Bool = false) -> String {
        let pieces = id.split(separator: "-")
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == 2, ignoringNonNumericParts || pieces.count == 2 else { return id }
        return shiftedID(year: numbers[0], month: numbers[1], by: months)
    }

    private static func shiftedID(year: Int, month: Int, by months: Int) -> String {
        let total = year * 12 + (month - 1) + months
        var shiftedYear = total / 12
        var shiftedMonth = total % 12
        if shiftedMonth < 0 {
            shiftedMonth += 12
            shiftedYear -= 1
        }
        // Calendar prints year 0 as 1 BC and so on: era year, not proleptic.
        return id(year: shiftedYear > 0 ? shiftedYear : 1 - shiftedYear, month: shiftedMonth + 1)
    }

    /// Nil unless the year is 1900...9999 and the month is 1...12.
    init?(year: Int, month: Int) {
        guard Self.validYears.contains(year), (1...12).contains(month) else {
            return nil
        }
        self.init(rawValue: Self.id(year: year, month: month))
    }

    /// Accepts `YYYY-MM`, `YYYY/MM`, `YYYY.MM` with any trailing content
    /// (`2026-07-15`) and a leading `YYYYMM` digit run. Out-of-range years and
    /// months return nil.
    init?(parsing value: String?) {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split { $0 == "-" || $0 == "/" || $0 == "." }
        if parts.count >= 2,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           let parsed = YearMonth(year: year, month: month) {
            self = parsed
            return
        }

        let digits = String(trimmed.prefix { $0.isNumber })
        guard digits.count >= 6 else {
            return nil
        }
        let yearEnd = digits.index(digits.startIndex, offsetBy: 4)
        let monthEnd = digits.index(yearEnd, offsetBy: 2)
        guard let year = Int(digits[..<yearEnd]),
              let month = Int(digits[yearEnd..<monthEnd]) else {
            return nil
        }
        self.init(year: year, month: month)
    }

    /// Canonical `YYYY-MM` for any input `init(parsing:)` accepts.
    static func canonicalID(_ value: String?) -> String? {
        YearMonth(parsing: value)?.rawValue
    }

    /// The month of a packed `YYYYMMDD` value that is a real calendar day
    /// (year 1...9999, Gregorian, GMT); nil for anything else, including a
    /// month or day outside its range.
    init?(validatingPackedDate packed: Int) {
        guard let dateID = PackedDate.validatedISO(packed) else { return nil }
        self.init(rawValue: String(dateID.prefix(7)))
    }
}
