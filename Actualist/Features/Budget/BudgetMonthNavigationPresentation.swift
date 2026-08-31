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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split { character in
            character == "-" || character == "/" || character == "."
        }
        if parts.count >= 2,
           let year = Int(parts[0]),
           let month = Int(parts[1]),
           let monthID = canonicalMonthID(year: year, month: month) {
            return monthID
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

        return canonicalMonthID(year: year, month: month)
    }

    private static func canonicalMonthID(year: Int, month: Int) -> String? {
        guard (1900...9999).contains(year), (1...12).contains(month) else {
            return nil
        }
        return String(format: "%04d-%02d", year, month)
    }
}
