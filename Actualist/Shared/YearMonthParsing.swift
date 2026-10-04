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
        guard packed > 0 else { return nil }
        let year = packed / 10_000
        let month = (packed / 100) % 100
        let day = packed % 100
        guard (1...9_999).contains(year) else { return nil }
        let dateID = String(format: "%04d-%02d-%02d", year, month, day)
        guard ActualDateOnly.date(from: dateID, timeZone: .gmt) != nil else { return nil }
        self.init(rawValue: String(dateID.prefix(7)))
    }
}
