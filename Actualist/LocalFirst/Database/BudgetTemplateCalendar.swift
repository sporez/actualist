import Foundation

enum BudgetTemplateCalendar {
    static let year = 1...9_999
    static let periodInterval = 1...1_200

    // Actual's months.ts parses date-only values at local noon so DST shifts
    // around midnight cannot format as the previous or next calendar day.
    static var gregorian: Calendar {
        Calendar(identifier: .gregorian)
    }

    static func validMonth(_ month: String?) -> Bool {
        guard let month,
              let value = try? parseMonth(month),
              (try? validatedMonth(value)) != nil else {
            return false
        }
        return true
    }

    static func parseMonth(_ month: String) throws -> Int {
        let normalized = month.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = normalized.replacingOccurrences(of: "-", with: "")
        guard compact.count == 6,
              let value = Int(compact) else {
            throw LocalFirstError.unsupportedTemplate("invalid by template")
        }
        return try validatedMonth(value)
    }

    static func validatedMonth(_ month: Int) throws -> Int {
        let year = month / 100
        let monthNumber = month % 100
        guard Self.year.contains(year),
              (1...12).contains(monthNumber) else {
            throw LocalFirstError.unsupportedTemplate(
                "template month is outside the supported range"
            )
        }
        return month
    }

    static func monthDistance(from currentMonth: Int, to targetMonth: Int) throws -> Int {
        try BudgetTemplateEngine.checkedSubtract(
            try monthOrdinal(targetMonth),
            try monthOrdinal(currentMonth)
        )
    }

    static func shiftedMonth(_ month: Int, by offset: Int) throws -> Int {
        let ordinal = try monthOrdinal(month)
        let shifted = ordinal.addingReportingOverflow(offset)
        guard !shifted.overflow,
              shifted.partialValue >= 0,
              shifted.partialValue < year.upperBound * 12 else {
            throw LocalFirstError.unsupportedTemplate(
                "template month is outside the supported range"
            )
        }
        let year = shifted.partialValue / 12 + 1
        let monthNumber = shifted.partialValue % 12 + 1
        return year * 100 + monthNumber
    }

    static func monthID(_ month: Int) -> String {
        String(format: "%04d-%02d", month / 100, month % 100)
    }

    static func currentMonthValue(now: Date = Date()) -> Int {
        let components = gregorian.dateComponents([.year, .month], from: now)
        return (components.year ?? 0) * 100 + (components.month ?? 0)
    }

    static func currentMonthID(now: Date = Date()) -> String {
        monthID(currentMonthValue(now: now))
    }

    static func daysInMonth(_ monthValue: Int) throws -> Int {
        let monthStart = try monthStartDate(monthValue)
        guard let range = gregorian.range(
            of: .day,
            in: .month,
            for: monthStart
        ) else {
            throw LocalFirstError.unsupportedTemplate(
                "template month is outside the supported range"
            )
        }
        return range.count
    }

    static func weeklyLimitOccurrenceCount(
        startingAt startDayID: String,
        monthValue: Int
    ) throws -> Int {
        guard let start = validatedDate(startDayID) else {
            throw LocalFirstError.unsupportedTemplate(
                "weekly limit requires a start date (YYYY-MM-DD)"
            )
        }
        let monthStart = try monthStartDate(monthValue)
        let nextMonthStart = try nextMonthStartDate(monthValue)

        let first: Date
        if start >= monthStart {
            first = start
        } else {
            let firstIndex = try firstWeeklyOccurrenceIndex(
                onOrAfter: monthStart,
                startingAt: start
            )
            first = try dateByAddingDays(firstIndex * 7, to: start)
        }
        guard first < nextMonthStart else {
            return 0
        }

        guard let daysToEnd = gregorian.dateComponents(
            [.day],
            from: first,
            to: nextMonthStart
        ).day,
              daysToEnd > 0 else {
            return 0
        }
        return (daysToEnd - 1) / 7 + 1
    }

    static func shiftedPeriodicDate(_ dayID: String, by amount: Int, period: String) throws -> String {
        guard periodInterval.contains(amount),
              let date = validatedDate(dayID) else {
            throw LocalFirstError.unsupportedTemplate("periodic start date")
        }
        var components = DateComponents()
        switch period {
        case "day":
            components.day = amount
        case "week":
            let multiplied = amount.multipliedReportingOverflow(by: 7)
            guard !multiplied.overflow else {
                throw LocalFirstError.unsupportedTemplate("periodic interval")
            }
            components.day = multiplied.partialValue
        case "month":
            components.month = amount
        case "year":
            components.year = amount
        default:
            throw LocalFirstError.unsupportedTemplate("periodic \(period)")
        }
        guard let shifted = gregorian.date(
            byAdding: components,
            to: date
        ) else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        let shiftedID = Self.dayID(from: shifted)
        guard validatedDate(shiftedID) != nil, shifted > date else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return shiftedID
    }

    static func periodicOccurrenceCount(
        startingAt start: Date,
        monthStart: Date,
        nextMonthStart: Date,
        interval: Int,
        period: String
    ) throws -> Int {
        guard periodInterval.contains(interval) else {
            throw LocalFirstError.unsupportedTemplate("periodic interval")
        }
        guard start < nextMonthStart else {
            return 0
        }

        switch period {
        case "day", "week":
            let step: Int
            if period == "week" {
                let multiplied = interval.multipliedReportingOverflow(by: 7)
                guard !multiplied.overflow else {
                    throw LocalFirstError.unsupportedTemplate("periodic interval")
                }
                step = multiplied.partialValue
            } else {
                step = interval
            }
            let calendar = gregorian
            let firstIndex: Int
            if start < monthStart {
                guard let daysToMonth = calendar.dateComponents(
                    [.day],
                    from: start,
                    to: monthStart
                ).day else {
                    throw LocalFirstError.unsupportedTemplate("periodic date")
                }
                let adjusted = try BudgetTemplateEngine.checkedAdd(daysToMonth, step - 1)
                firstIndex = adjusted / step
            } else {
                firstIndex = 0
            }
            guard let daysToEnd = calendar.dateComponents(
                [.day],
                from: start,
                to: nextMonthStart
            ).day,
                  daysToEnd > 0 else {
                return 0
            }
            let lastIndex = (daysToEnd - 1) / step
            guard lastIndex >= firstIndex else {
                return 0
            }
            return try BudgetTemplateEngine.checkedAdd(
                try BudgetTemplateEngine.checkedSubtract(lastIndex, firstIndex),
                1
            )
        case "month", "year":
            let firstIndex = try firstCalendarOccurrenceIndex(
                onOrAfter: monthStart,
                startingAt: start,
                interval: interval,
                period: period
            )
            let occurrence = try periodicOccurrenceDate(
                startingAt: start,
                index: firstIndex,
                interval: interval,
                period: period
            )
            return occurrence < nextMonthStart ? 1 : 0
        default:
            throw LocalFirstError.unsupportedTemplate("periodic \(period)")
        }
    }

    static func validatedDate(_ dayID: String) -> Date? {
        let normalized = dayID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              Self.year.contains(year),
              let date = gregorian.date(
                from: DateComponents(year: year, month: month, day: day, hour: 12)
              ),
              Self.dayID(from: date) == normalized else {
            return nil
        }
        return date
    }

    static func dayID(from date: Date) -> String {
        let components = gregorian.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func monthStartDate(_ monthValue: Int) throws -> Date {
        let monthStart = "\(monthID(try validatedMonth(monthValue)))-01"
        guard let date = validatedDate(monthStart) else {
            throw LocalFirstError.unsupportedTemplate("periodic month")
        }
        return date
    }

    static func nextMonthStartDate(_ monthValue: Int) throws -> Date {
        let monthStart = try monthStartDate(monthValue)
        guard let next = gregorian.date(byAdding: .month, value: 1, to: monthStart) else {
            throw LocalFirstError.unsupportedTemplate("periodic month")
        }
        return next
    }

    private static func monthOrdinal(_ month: Int) throws -> Int {
        let month = try validatedMonth(month)
        return (month / 100 - 1) * 12 + (month % 100 - 1)
    }

    private static func firstWeeklyOccurrenceIndex(
        onOrAfter target: Date,
        startingAt start: Date
    ) throws -> Int {
        guard start < target else {
            return 0
        }
        guard let daysToTarget = gregorian.dateComponents(
            [.day],
            from: start,
            to: target
        ).day else {
            throw LocalFirstError.unsupportedTemplate("weekly limit date")
        }
        let adjusted = try BudgetTemplateEngine.checkedAdd(daysToTarget, 6)
        return adjusted / 7
    }

    private static func dateByAddingDays(_ days: Int, to date: Date) throws -> Date {
        guard let shifted = gregorian.date(
            byAdding: .day,
            value: days,
            to: date
        ) else {
            throw LocalFirstError.unsupportedTemplate("weekly limit date")
        }
        return shifted
    }

    private static func firstCalendarOccurrenceIndex(
        onOrAfter target: Date,
        startingAt start: Date,
        interval: Int,
        period: String
    ) throws -> Int {
        guard start < target else {
            return 0
        }
        let calendar = gregorian
        let startComponents = calendar.dateComponents([.year, .month], from: start)
        let targetComponents = calendar.dateComponents([.year, .month], from: target)
        guard let startYear = startComponents.year,
              let startMonth = startComponents.month,
              let targetYear = targetComponents.year,
              let targetMonth = targetComponents.month else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }

        let distance: Int
        if period == "year" {
            distance = try BudgetTemplateEngine.checkedSubtract(targetYear, startYear)
        } else {
            let yearDistance = try BudgetTemplateEngine.checkedSubtract(targetYear, startYear)
            let monthDistance = yearDistance.multipliedReportingOverflow(by: 12)
            guard !monthDistance.overflow else {
                throw LocalFirstError.unsupportedTemplate("periodic date")
            }
            distance = try BudgetTemplateEngine.checkedAdd(
                monthDistance.partialValue,
                try BudgetTemplateEngine.checkedSubtract(targetMonth, startMonth)
            )
        }
        var index = max(0, distance / interval)
        var occurrence = try periodicOccurrenceDate(
            startingAt: start,
            index: index,
            interval: interval,
            period: period
        )
        if occurrence < target {
            index = try BudgetTemplateEngine.checkedAdd(index, 1)
            occurrence = try periodicOccurrenceDate(
                startingAt: start,
                index: index,
                interval: interval,
                period: period
            )
        }
        guard occurrence >= target else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return index
    }

    private static func periodicOccurrenceDate(
        startingAt start: Date,
        index: Int,
        interval: Int,
        period: String
    ) throws -> Date {
        let multiplied = interval.multipliedReportingOverflow(by: index)
        guard !multiplied.overflow else {
            throw LocalFirstError.unsupportedTemplate("periodic interval")
        }
        let component: Calendar.Component = period == "year" ? .year : .month
        guard let occurrence = gregorian.date(
            byAdding: component,
            value: multiplied.partialValue,
            to: start
        ) else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        let occurrenceID = Self.dayID(from: occurrence)
        guard validatedDate(occurrenceID) != nil else {
            throw LocalFirstError.unsupportedTemplate("periodic date")
        }
        return occurrence
    }
}
