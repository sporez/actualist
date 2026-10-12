import Foundation

/// A date condition whose value is a schedule-style recurrence. Actual evaluates `is` as "the
/// recurrence occurs on this day" and `isapprox` as "it occurs within two days either side". Its
/// condition path does not move weekend dates, so the weekend adjustment is not applied here.
enum RuleRecurrenceDateMatcher {
    static func matches(dayID: String, operation: String, recurrence value: RuleJSONValue) -> Bool {
        guard ["is", "isapprox"].contains(operation),
              let recurrence = try? ScheduleRuleProjection.recurrence(from: value) else { return false }
        let calendar = Calendar.actualScheduleGregorian
        guard let day = ActualScheduleRecurrence.date(from: dayID, calendar: calendar) else { return false }
        let radius = operation == "isapprox" ? 2 : 0
        guard let first = calendar.date(byAdding: .day, value: -radius, to: day),
              let last = calendar.date(byAdding: .day, value: radius, to: day),
              let next = try? recurrence.nextOccurrence(
                  onOrAfter: ActualScheduleRecurrence.dayID(from: first, calendar: calendar),
                  applyWeekendAdjustment: false,
                  calendar: calendar
              ) else { return false }
        return next <= ActualScheduleRecurrence.dayID(from: last, calendar: calendar)
    }
}
