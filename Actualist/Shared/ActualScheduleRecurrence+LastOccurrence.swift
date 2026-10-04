import Foundation

extension ActualScheduleRecurrence {
    private static let lastOccurrenceIterationLimit = 20_000

    /// The final occurrence of an ending recurrence, or nil when it never ends
    /// or the end precedes the first occurrence. Mirrors Actual's `getNextDate`
    /// fallback (`occurrences({ reverse: true, take: 1 })`), including the
    /// weekend move applied to that date.
    func lastOccurrence(
        applyWeekendAdjustment: Bool = true,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> String? {
        guard ending != .never,
              let start = Self.date(from: startDayID, calendar: calendar) else { return nil }
        let natural: Date?
        switch frequencyValue {
        case .daily, .weekly:
            natural = try lastLinearOccurrence(start: start, calendar: calendar)
        case .monthly, .yearly:
            natural = try lastIteratedOccurrence(calendar: calendar)
        }
        guard let natural else { return nil }
        let display = applyWeekendAdjustment ? try skippedWeekend(natural, calendar: calendar) : natural
        return Self.dayID(from: display, calendar: calendar)
    }

    private func lastLinearOccurrence(start: Date, calendar: Calendar) throws -> Date? {
        let step = frequencyValue == .weekly ? interval * 7 : interval
        let index: Int
        switch ending {
        case .never:
            return nil
        case .afterOccurrences(let count):
            index = count - 1
        case .onDate(let endDayID):
            guard let end = Self.date(from: endDayID, calendar: calendar),
                  let distance = calendar.dateComponents([.day], from: start, to: end).day,
                  distance >= 0 else { return nil }
            index = distance / step
        }
        let offset = index.multipliedReportingOverflow(by: step)
        guard !offset.overflow else { return nil }
        return calendar.date(byAdding: .day, value: offset.partialValue, to: start)
    }

    /// Walks natural occurrences so split monthly rules keep Actual's per-family
    /// counting. A bounded walk beyond the limit reports no last occurrence.
    private func lastIteratedOccurrence(calendar: Calendar) throws -> Date? {
        var cursor = startDayID
        var last: String?
        for _ in 0..<Self.lastOccurrenceIterationLimit {
            guard let next = try nextOccurrence(
                onOrAfter: cursor,
                applyWeekendAdjustment: false,
                calendar: calendar
            ) else {
                return last.flatMap { Self.date(from: $0, calendar: calendar) }
            }
            last = next
            guard let nextDate = Self.date(from: next, calendar: calendar),
                  let dayAfter = calendar.date(byAdding: .day, value: 1, to: nextDate) else {
                return nil
            }
            cursor = Self.dayID(from: dayAfter, calendar: calendar)
        }
        return nil
    }
}
