import Foundation

enum ActualScheduleFrequency: String, Codable, Hashable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly
}

enum ActualScheduleWeekday: String, Codable, Hashable, Sendable {
    case sunday = "SU"
    case monday = "MO"
    case tuesday = "TU"
    case wednesday = "WE"
    case thursday = "TH"
    case friday = "FR"
    case saturday = "SA"

    var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }
}

enum ActualSchedulePattern: Hashable, Sendable {
    case dayOfMonth(Int)
    case weekday(ActualScheduleWeekday, ordinal: Int)
}

enum ActualScheduleEnding: Hashable, Sendable {
    case never
    case afterOccurrences(Int)
    case onDate(String)
}

enum ActualScheduleWeekendAdjustment: String, Codable, Hashable, Sendable {
    case before
    case after
}

enum ActualScheduleRecurrenceError: Error, Equatable, Sendable {
    case invalidStartDate
    case invalidFrequency
    case invalidInterval
    case invalidPattern
    case invalidEnding
    case invalidSkipWeekend
    case invalidWeekendAdjustment
    case occurrenceLimitExceeded
}

/// Actual's date-only recurrence contract. All identity and comparisons remain
/// civil `YYYY-MM-DD` values; `Date` conversion uses local noon in the supplied
/// Gregorian calendar so a DST transition cannot move an occurrence by a day.
struct ActualScheduleRecurrence: Hashable, Sendable {
    let startDayID: String
    let frequencyValue: ActualScheduleFrequency
    let interval: Int
    let patterns: [ActualSchedulePattern]
    let skipWeekend: Bool
    let weekendAdjustment: ActualScheduleWeekendAdjustment
    let ending: ActualScheduleEnding

    var frequency: String { frequencyValue.rawValue }

    init(
        startDayID: String,
        frequency: ActualScheduleFrequency,
        interval: Int = 1,
        patterns: [ActualSchedulePattern] = [],
        skipWeekend: Bool = false,
        weekendAdjustment: ActualScheduleWeekendAdjustment = .after,
        ending: ActualScheduleEnding = .never,
        calendar: Calendar = .actualScheduleGregorian
    ) throws {
        guard Self.date(from: startDayID, calendar: calendar) != nil else {
            throw ActualScheduleRecurrenceError.invalidStartDate
        }
        guard interval > 0 else {
            throw ActualScheduleRecurrenceError.invalidInterval
        }
        if frequency == .weekly, interval > Int.max / 7 {
            throw ActualScheduleRecurrenceError.invalidInterval
        }
        guard patterns.allSatisfy(Self.isValidPattern) else {
            throw ActualScheduleRecurrenceError.invalidPattern
        }
        switch ending {
        case .never:
            break
        case .afterOccurrences(let count):
            guard count > 0 else { throw ActualScheduleRecurrenceError.invalidEnding }
        case .onDate(let dayID):
            guard Self.date(from: dayID, calendar: calendar) != nil else {
                throw ActualScheduleRecurrenceError.invalidEnding
            }
        }
        self.startDayID = startDayID
        self.frequencyValue = frequency
        self.interval = interval
        self.patterns = patterns
        self.skipWeekend = skipWeekend
        self.weekendAdjustment = weekendAdjustment
        self.ending = ending
    }

    func nextDateString(
        onOrAfter startDate: Date,
        applyWeekendSkip: Bool,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> String? {
        try nextOccurrence(
            onOrAfter: Self.dayID(from: startDate, calendar: calendar),
            applyWeekendAdjustment: applyWeekendSkip,
            calendar: calendar
        )
    }

    func nextDate(
        onOrAfter startDate: Date,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> Date? {
        guard let dayID = try nextOccurrence(
            onOrAfter: Self.dayID(from: startDate, calendar: calendar),
            applyWeekendAdjustment: false,
            calendar: calendar
        ) else {
            return nil
        }
        return Self.date(from: dayID, calendar: calendar)
    }

    func nextOccurrence(
        onOrAfter targetDayID: String,
        applyWeekendAdjustment: Bool = true,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> String? {
        guard let target = Self.date(from: targetDayID, calendar: calendar),
              let recurrenceStart = Self.date(from: startDayID, calendar: calendar) else {
            throw ActualScheduleRecurrenceError.invalidStartDate
        }
        var cursor = max(target, recurrenceStart)
        while let natural = try nextNaturalOccurrence(onOrAfter: cursor, calendar: calendar) {
            let naturalID = Self.dayID(from: natural, calendar: calendar)
            if try isWithinEnding(naturalDayID: naturalID, calendar: calendar) {
                // Actual chooses the natural occurrence first and only then
                // moves a weekend date. A `.before` result can therefore
                // precede the search date.
                let display = applyWeekendAdjustment
                    ? try skippedWeekend(natural, calendar: calendar)
                    : natural
                return Self.dayID(from: display, calendar: calendar)
            }
            guard case .afterOccurrences(let count) = ending,
                  try splitMonthlyRulesHaveRemaining(after: natural, count: count, calendar: calendar),
                  let next = calendar.date(byAdding: .day, value: 1, to: natural) else {
                return nil
            }
            cursor = next
        }
        return nil
    }

    func skippedWeekend(
        _ date: Date,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> Date {
        guard skipWeekend else { return date }
        let weekday = calendar.component(.weekday, from: date)
        guard weekday == 1 || weekday == 7 else { return date }
        let offset: Int
        switch weekendAdjustment {
        case .after:
            offset = weekday == 7 ? 2 : 1
        case .before:
            offset = weekday == 7 ? -1 : -2
        }
        guard let adjusted = calendar.date(byAdding: .day, value: offset, to: date) else {
            throw ActualScheduleRecurrenceError.invalidWeekendAdjustment
        }
        return adjusted
    }

    private func nextNaturalOccurrence(onOrAfter target: Date, calendar: Calendar) throws -> Date? {
        switch frequencyValue {
        case .daily, .weekly:
            guard let start = Self.date(from: startDayID, calendar: calendar),
                  let distance = calendar.dateComponents([.day], from: start, to: target).day else {
                return nil
            }
            let step: Int
            if frequencyValue == .weekly {
                let result = interval.multipliedReportingOverflow(by: 7)
                guard !result.overflow else {
                    throw ActualScheduleRecurrenceError.invalidInterval
                }
                step = result.partialValue
            } else {
                step = interval
            }
            let positiveDistance = max(distance, 0)
            let index = positiveDistance / step + (positiveDistance % step == 0 ? 0 : 1)
            let offset = index.multipliedReportingOverflow(by: step)
            guard !offset.overflow else {
                throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
            }
            return calendar.date(byAdding: .day, value: offset.partialValue, to: start)
        case .monthly:
            return try nextMonthlyOccurrence(onOrAfter: target, calendar: calendar)
        case .yearly:
            return try nextYearlyOccurrence(onOrAfter: target, calendar: calendar)
        }
    }

    private func nextMonthlyOccurrence(onOrAfter target: Date, calendar: Calendar) throws -> Date? {
        guard let start = Self.date(from: startDayID, calendar: calendar) else { return nil }
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        let targetParts = calendar.dateComponents([.year, .month], from: target)
        guard let startYear = startParts.year, let startMonth = startParts.month,
              let startDay = startParts.day, let targetYear = targetParts.year,
              let targetMonth = targetParts.month else { return nil }
        let startOrdinal = startYear * 12 + startMonth - 1
        let targetOrdinal = targetYear * 12 + targetMonth - 1
        let ordinalDistance = max(targetOrdinal - startOrdinal, 0)
        var monthIndex = (ordinalDistance / interval) * interval
        for _ in 0..<120_000 {
            let ordinalResult = startOrdinal.addingReportingOverflow(monthIndex)
            guard !ordinalResult.overflow else { return nil }
            let ordinal = ordinalResult.partialValue
            guard ordinal <= 9_999 * 12 + 11 else { return nil }
            let year = ordinal / 12
            let month = ordinal % 12 + 1
            let candidates = patterns.isEmpty
                ? Self.validDates(year: year, month: month, days: [startDay], calendar: calendar)
                : Self.patternDates(year: year, month: month, patterns: patterns, calendar: calendar)
            if let candidate = candidates.first(where: { $0 >= target && $0 >= start }) {
                return candidate
            }
            let nextIndex = monthIndex.addingReportingOverflow(interval)
            guard !nextIndex.overflow else { return nil }
            monthIndex = nextIndex.partialValue
        }
        throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
    }

    private func nextYearlyOccurrence(onOrAfter target: Date, calendar: Calendar) throws -> Date? {
        guard let start = Self.date(from: startDayID, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        let targetYear = calendar.component(.year, from: target)
        guard let startYear = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let yearDistance = max(targetYear - startYear, 0)
        let yearOffset = (yearDistance / interval) * interval
        let initialYear = startYear.addingReportingOverflow(yearOffset)
        guard !initialYear.overflow else {
            throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
        }
        var year = initialYear.partialValue
        for _ in 0..<10_000 {
            guard year <= 9_999 else { return nil }
            if let candidate = Self.validDate(year: year, month: month, day: day, calendar: calendar),
               candidate >= target {
                return candidate
            }
            let nextYear = year.addingReportingOverflow(interval)
            guard !nextYear.overflow else { return nil }
            year = nextYear.partialValue
        }
        throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
    }

    private func isWithinEnding(naturalDayID: String, calendar: Calendar) throws -> Bool {
        switch ending {
        case .never:
            return true
        case .onDate(let endDayID):
            return naturalDayID <= endDayID
        case .afterOccurrences(let count):
            guard let natural = Self.date(from: naturalDayID, calendar: calendar) else { return false }
            if frequencyValue == .monthly {
                let dayPatterns = patterns.filter {
                    if case .dayOfMonth = $0 { return true }
                    return false
                }
                let weekdayPatterns = patterns.filter {
                    if case .weekday = $0 { return true }
                    return false
                }
                if !dayPatterns.isEmpty, !weekdayPatterns.isEmpty {
                    let dayOrdinal = try occurrenceOrdinal(
                        of: natural,
                        monthlyPatterns: dayPatterns,
                        calendar: calendar
                    )
                    let weekdayOrdinal = try occurrenceOrdinal(
                        of: natural,
                        monthlyPatterns: weekdayPatterns,
                        calendar: calendar
                    )
                    return dayOrdinal.map { $0 <= count } == true
                        || weekdayOrdinal.map { $0 <= count } == true
                }
            }
            guard let ordinal = try occurrenceOrdinal(of: natural, calendar: calendar) else { return false }
            return ordinal <= count
        }
    }

    private func occurrenceOrdinal(
        of natural: Date,
        monthlyPatterns: [ActualSchedulePattern]? = nil,
        calendar: Calendar
    ) throws -> Int? {
        guard let start = Self.date(from: startDayID, calendar: calendar) else { return nil }
        switch frequencyValue {
        case .daily, .weekly:
            guard let distance = calendar.dateComponents([.day], from: start, to: natural).day else {
                return nil
            }
            let step: Int
            if frequencyValue == .weekly {
                let result = interval.multipliedReportingOverflow(by: 7)
                guard !result.overflow else {
                    throw ActualScheduleRecurrenceError.invalidInterval
                }
                step = result.partialValue
            } else {
                step = interval
            }
            guard distance >= 0, distance % step == 0 else { return nil }
            return distance / step + 1
        case .monthly:
            let startParts = calendar.dateComponents([.year, .month, .day], from: start)
            let naturalParts = calendar.dateComponents([.year, .month], from: natural)
            guard let startYear = startParts.year, let startMonth = startParts.month,
                  let startDay = startParts.day, let naturalYear = naturalParts.year,
                  let naturalMonth = naturalParts.month else { return nil }
            let startOrdinal = startYear * 12 + startMonth - 1
            let naturalOrdinal = naturalYear * 12 + naturalMonth - 1
            let effectivePatterns = monthlyPatterns ?? patterns
            var monthOrdinal = startOrdinal
            var occurrenceCount = 0
            while monthOrdinal <= naturalOrdinal {
                let year = monthOrdinal / 12
                let month = monthOrdinal % 12 + 1
                let candidates = effectivePatterns.isEmpty
                    ? Self.validDates(year: year, month: month, days: [startDay], calendar: calendar)
                    : Self.patternDates(year: year, month: month, patterns: effectivePatterns, calendar: calendar)
                for candidate in candidates where candidate >= start && candidate <= natural {
                    occurrenceCount += 1
                    if candidate == natural { return occurrenceCount }
                }
                let nextMonth = monthOrdinal.addingReportingOverflow(interval)
                guard !nextMonth.overflow else {
                    throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
                }
                monthOrdinal = nextMonth.partialValue
            }
            return nil
        case .yearly:
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let naturalYear = calendar.component(.year, from: natural)
            guard let startYear = parts.year, let month = parts.month, let day = parts.day else {
                return nil
            }
            var year = startYear
            var occurrenceCount = 0
            while year <= naturalYear {
                if let candidate = Self.validDate(year: year, month: month, day: day, calendar: calendar),
                   candidate >= start, candidate <= natural {
                    occurrenceCount += 1
                    if candidate == natural { return occurrenceCount }
                }
                let nextYear = year.addingReportingOverflow(interval)
                guard !nextYear.overflow else {
                    throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
                }
                year = nextYear.partialValue
            }
            return nil
        }
    }

    private func splitMonthlyRulesHaveRemaining(
        after natural: Date,
        count: Int,
        calendar: Calendar
    ) throws -> Bool {
        guard frequencyValue == .monthly else { return false }
        let dayPatterns = patterns.filter {
            if case .dayOfMonth = $0 { return true }
            return false
        }
        let weekdayPatterns = patterns.filter {
            if case .weekday = $0 { return true }
            return false
        }
        guard !dayPatterns.isEmpty, !weekdayPatterns.isEmpty else { return false }
        let dayCount = try monthlyOccurrenceCount(
            through: natural,
            patterns: dayPatterns,
            stoppingAt: count,
            calendar: calendar
        )
        if dayCount < count { return true }
        return try monthlyOccurrenceCount(
            through: natural,
            patterns: weekdayPatterns,
            stoppingAt: count,
            calendar: calendar
        ) < count
    }

    private func monthlyOccurrenceCount(
        through natural: Date,
        patterns: [ActualSchedulePattern],
        stoppingAt limit: Int,
        calendar: Calendar
    ) throws -> Int {
        guard let start = Self.date(from: startDayID, calendar: calendar) else { return 0 }
        let startParts = calendar.dateComponents([.year, .month], from: start)
        let naturalParts = calendar.dateComponents([.year, .month], from: natural)
        guard let startYear = startParts.year, let startMonth = startParts.month,
              let naturalYear = naturalParts.year, let naturalMonth = naturalParts.month else { return 0 }
        var monthOrdinal = startYear * 12 + startMonth - 1
        let naturalOrdinal = naturalYear * 12 + naturalMonth - 1
        var occurrenceCount = 0
        while monthOrdinal <= naturalOrdinal {
            let year = monthOrdinal / 12
            let month = monthOrdinal % 12 + 1
            let candidates = Self.patternDates(
                year: year,
                month: month,
                patterns: patterns,
                calendar: calendar
            )
            for candidate in candidates where candidate >= start && candidate <= natural {
                occurrenceCount += 1
                if occurrenceCount >= limit { return occurrenceCount }
            }
            let nextMonth = monthOrdinal.addingReportingOverflow(interval)
            guard !nextMonth.overflow else {
                throw ActualScheduleRecurrenceError.occurrenceLimitExceeded
            }
            monthOrdinal = nextMonth.partialValue
        }
        return occurrenceCount
    }

    private static func isValidPattern(_ pattern: ActualSchedulePattern) -> Bool {
        switch pattern {
        case .dayOfMonth(let day):
            return day != 0 && (-31...31).contains(day)
        case .weekday(_, let ordinal):
            return ordinal != 0 && (-5...5).contains(ordinal)
        }
    }

    private static func patternDates(
        year: Int,
        month: Int,
        patterns: [ActualSchedulePattern],
        calendar: Calendar
    ) -> [Date] {
        let values = patterns.compactMap { pattern -> Date? in
            switch pattern {
            case .dayOfMonth(let value):
                guard let days = calendar.range(
                    of: .day,
                    in: .month,
                    for: validDate(year: year, month: month, day: 1, calendar: calendar) ?? Date()
                )?.count else { return nil }
                let day = value > 0 ? value : days + value + 1
                return validDate(year: year, month: month, day: day, calendar: calendar)
            case .weekday(let weekday, let ordinal):
                return nthWeekday(
                    weekday.calendarWeekday,
                    ordinal: ordinal,
                    year: year,
                    month: month,
                    calendar: calendar
                )
            }
        }
        return Array(Set(values)).sorted()
    }

    private static func nthWeekday(
        _ weekday: Int,
        ordinal: Int,
        year: Int,
        month: Int,
        calendar: Calendar
    ) -> Date? {
        guard let first = validDate(year: year, month: month, day: 1, calendar: calendar),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        if ordinal > 0 {
            let offset = (weekday - calendar.component(.weekday, from: first) + 7) % 7
            return validDate(year: year, month: month, day: 1 + offset + (ordinal - 1) * 7, calendar: calendar)
        }
        guard let last = validDate(year: year, month: month, day: range.count, calendar: calendar) else { return nil }
        let offset = (calendar.component(.weekday, from: last) - weekday + 7) % 7
        return validDate(year: year, month: month, day: range.count - offset + (ordinal + 1) * 7, calendar: calendar)
    }

    private static func validDates(year: Int, month: Int, days: [Int], calendar: Calendar) -> [Date] {
        days.compactMap { validDate(year: year, month: month, day: $0, calendar: calendar) }.sorted()
    }

    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    static func date(from dayID: String, calendar: Calendar = .actualScheduleGregorian) -> Date? {
        let parts = dayID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9_999).contains(year) else { return nil }
        return validDate(year: year, month: month, day: day, calendar: calendar)
    }

    static func dayID(from date: Date, calendar: Calendar = .actualScheduleGregorian) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension Calendar {
    static var actualScheduleGregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .gmt
        return calendar
    }
}
