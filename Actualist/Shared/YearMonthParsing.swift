import Foundation

extension YearMonth {
    static let validYears = 1900...9999

    /// Nil unless the year is 1900...9999 and the month is 1...12.
    init?(year: Int, month: Int) {
        guard Self.validYears.contains(year), (1...12).contains(month) else {
            return nil
        }
        self.init(rawValue: String(format: "%04d-%02d", year, month))
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
}
