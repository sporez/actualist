import Foundation

/// The six date orders Actual's import offers (`dateFormats`, import modal
/// `utils.ts`), in Actual's order. The raw value is Actual's own key, which
/// is also what its `parse-date-<account>-<type>` preference stores.
enum ImportDateFormat: String, CaseIterable, Sendable {
    case yyyyMMdd = "yyyy mm dd"
    case yyMMdd = "yy mm dd"
    case mmDDyyyy = "mm dd yyyy"
    case mmDDyy = "mm dd yy"
    case ddMMyyyy = "dd mm yyyy"
    case ddMMyy = "dd mm yy"

    /// Actual's label for the format.
    var label: String { rawValue.uppercased() }
}

/// Ports of the import modal's date reading (pinned Actual v26.11.0):
/// `parseDate` (`utils.ts`) and `getInitialDateFormat`
/// (`ImportTransactionsModal.tsx`). The `file-import` oracle replays both.
enum ImportDateParsing {
    /// `parseDate(str, order)`: an ISO `yyyy-MM-dd` day, or `nil` (JS `null`)
    /// when the text does not read as a real day in that order.
    static func parseDate(_ text: String?, format: ImportDateFormat) -> String? {
        guard let text else { return nil }
        let parts: [String]
        let year: String
        let month: String
        let day: String
        switch format {
        case .ddMMyyyy:
            parts = dateGroups(text, 2, 2)
            (year, month, day) = (parts[2], parts[1], parts[0])
        case .ddMMyy:
            parts = dateGroups(text, 2, 2)
            (year, month, day) = ("20" + parts[2], parts[1], parts[0])
        case .yyyyMMdd:
            parts = dateGroups(text, 4, 2)
            (year, month, day) = (parts[0], parts[1], parts[2])
        case .yyMMdd:
            parts = dateGroups(text, 2, 2)
            (year, month, day) = ("20" + parts[0], parts[1], parts[2])
        case .mmDDyy:
            parts = dateGroups(text, 2, 2)
            (year, month, day) = ("20" + parts[2], parts[0], parts[1])
        case .mmDDyyyy:
            parts = dateGroups(text, 2, 2)
            (year, month, day) = (parts[2], parts[0], parts[1])
        }
        let paddedMonth = pad(month)
        let paddedDay = pad(day)
        guard isValidISODay(year: year, month: paddedMonth, day: paddedDay) else { return nil }
        return "\(year)-\(paddedMonth)-\(paddedDay)"
    }

    /// `getInitialDateFormat`: the first format that reads the first row's
    /// date. With no rows or no date column it is `yyyy mm dd`; when nothing
    /// reads the value it is `mm dd yyyy`.
    static func initialDateFormat(rowCount: Int, firstDateValue: String?, hasDateColumn: Bool) -> ImportDateFormat {
        guard rowCount > 0, hasDateColumn else { return .yyyyMMdd }
        guard let firstDateValue else { return .mmDDyyyy }
        return ImportDateFormat.allCases.first { parseDate(firstDateValue, format: $0) != nil } ?? .mmDDyyyy
    }

    // MARK: - dateGroups

    /// `dateGroups(a, b)(str)`: three digit groups, after month names become
    /// numbers; with fewer than three groups, the original text's digits are
    /// cut at `a` and `a + b`.
    private static func dateGroups(_ text: String, _ first: Int, _ second: Int) -> [String] {
        var scalars = Array(text.unicodeScalars)
        for name in monthNames {
            scalars = replacingFirstMonthName(name, in: scalars)
        }
        // `.replace(/^[^\d]+/, '').replace(/[^\d]+$/, '')`
        let start = scalars.firstIndex(where: JavaScriptText.isDigit) ?? scalars.count
        let end = scalars.lastIndex(where: JavaScriptText.isDigit).map { $0 + 1 } ?? start
        let trimmed = start < end ? Array(scalars[start..<end]) : []
        // `.split(/[^\d]+/)`; an empty string splits to `[""]`.
        var parts: [String] = []
        var current: [Unicode.Scalar] = []
        for scalar in trimmed {
            if JavaScriptText.isDigit(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                parts.append(JavaScriptText.string(current))
                current = []
            }
        }
        parts.append(JavaScriptText.string(current))
        if parts.count >= 3 {
            return Array(parts.prefix(3))
        }
        let digits = Array(text.unicodeScalars.filter(JavaScriptText.isDigit))
        func slice(_ from: Int, _ to: Int?) -> String {
            let lower = min(from, digits.count)
            let upper = to.map { min($0, digits.count) } ?? digits.count
            return lower < upper ? JavaScriptText.string(digits[lower..<upper]) : ""
        }
        return [slice(0, first), slice(first, first + second), slice(first + second, nil)]
    }

    /// One `/\b<base>(<suffixes>)?\b/i` pattern; `suffixes` are tried in the
    /// regex's backtracking order and end with `""` (the group skipped).
    private struct MonthName {
        let base: String
        let suffixes: [String]
        let number: String
    }

    private static let monthNames: [MonthName] = [
        MonthName(base: "jan", suffixes: [".", "uary", ""], number: "01"),
        MonthName(base: "feb", suffixes: [".", "ruary", ""], number: "02"),
        MonthName(base: "mar", suffixes: [".", "ch", ""], number: "03"),
        MonthName(base: "apr", suffixes: [".", "il", ""], number: "04"),
        MonthName(base: "may", suffixes: [".", ""], number: "05"),
        MonthName(base: "jun", suffixes: [".", "e", ""], number: "06"),
        MonthName(base: "jul", suffixes: [".", "y", ""], number: "07"),
        MonthName(base: "aug", suffixes: [".", "ust", ""], number: "08"),
        MonthName(base: "sep", suffixes: [".", "t.", "t", "tember", ""], number: "09"),
        MonthName(base: "oct", suffixes: [".", "ober", ""], number: "10"),
        MonthName(base: "nov", suffixes: [".", "ember", ""], number: "11"),
        MonthName(base: "dec", suffixes: [".", "ember", ""], number: "12"),
    ]

    /// `str.replace(pattern, number)`: replaces the leftmost match only.
    private static func replacingFirstMonthName(_ name: MonthName, in text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let base = Array(name.base.unicodeScalars)
        guard text.count >= base.count else { return text }
        for start in 0...(text.count - base.count) where isWordBoundary(text, at: start) {
            guard matchesIgnoringASCIICase(text, at: start, base) else { continue }
            for suffix in name.suffixes {
                let suffixScalars = Array(suffix.unicodeScalars)
                let suffixStart = start + base.count
                guard matchesIgnoringASCIICase(text, at: suffixStart, suffixScalars) else { continue }
                let end = suffixStart + suffixScalars.count
                if isWordBoundary(text, at: end) {
                    return Array(text[..<start]) + Array(name.number.unicodeScalars) + Array(text[end...])
                }
            }
        }
        return text
    }

    private static func matchesIgnoringASCIICase(_ text: [Unicode.Scalar], at start: Int, _ pattern: [Unicode.Scalar]) -> Bool {
        guard start + pattern.count <= text.count else { return false }
        for (offset, scalar) in pattern.enumerated()
        where JavaScriptText.asciiLowercased(text[start + offset]) != scalar {
            return false
        }
        return true
    }

    /// `\b`: a word character on exactly one side.
    private static func isWordBoundary(_ text: [Unicode.Scalar], at index: Int) -> Bool {
        let before = index > 0 && JavaScriptText.isWordCharacter(text[index - 1])
        let after = index < text.count && JavaScriptText.isWordCharacter(text[index])
        return before != after
    }

    /// `pad`: a one-character part gets a leading zero.
    private static func pad(_ value: String) -> String {
        value.unicodeScalars.count == 1 ? "0" + value : value
    }

    // MARK: - date-fns parseISO validity

    /// `isValid(parseISO("\(year)-\(month)-\(day)"))` for ASCII-digit parts,
    /// as date-fns 4.4.0 decides it. `parseYear` takes four leading digits,
    /// and the rest must be `-MM-DD`, so the year must be exactly four
    /// digits, month and day exactly two, and the day must exist. Year 0000
    /// is a leap year.
    private static func isValidISODay(year: String, month: String, day: String) -> Bool {
        guard year.unicodeScalars.count == 4, month.unicodeScalars.count == 2, day.unicodeScalars.count == 2,
              let yearNumber = Int(year), let monthNumber = Int(month), let dayNumber = Int(day),
              (1...12).contains(monthNumber), dayNumber >= 1 else {
            return false
        }
        let isLeap = yearNumber % 400 == 0 || (yearNumber % 4 == 0 && yearNumber % 100 != 0)
        let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return dayNumber <= daysInMonth[monthNumber - 1]
    }
}
