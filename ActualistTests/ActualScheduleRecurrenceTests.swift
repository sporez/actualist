import Foundation
import Testing
@testable import Actualist

@Suite("Actual schedule recurrence")
struct ActualScheduleRecurrenceTests {
    @Test func oneTimeDateIsRepresentedOutsideRecurrence() {
        let rule = ScheduleDateRule.oneTime(dayID: "2026-09-30", operation: "is")
        #expect(rule.recurrence == nil)
        #expect(rule.usesExactOccurrenceMatching)
    }

    @Test func dailyAndInterval() throws {
        let daily = try recurrence(start: "2026-09-01", frequency: .daily)
        let everyThreeDays = try recurrence(start: "2026-09-01", frequency: .daily, interval: 3)
        #expect(try daily.nextOccurrence(onOrAfter: "2026-09-04") == "2026-09-04")
        #expect(try everyThreeDays.nextOccurrence(onOrAfter: "2026-09-02") == "2026-09-04")
    }

    @Test func weeklyAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let weekly = try recurrence(
            start: "2026-03-01",
            frequency: .weekly,
            interval: 1,
            calendar: newYork
        )
        #expect(
            try weekly.nextOccurrence(
                onOrAfter: "2026-03-08",
                calendar: newYork
            ) == "2026-03-08"
        )
        #expect(
            try weekly.nextOccurrence(
                onOrAfter: "2026-03-09",
                calendar: newYork
            ) == "2026-03-15"
        )
    }

    @Test func monthlyMultipleDays() throws {
        let monthly = try recurrence(
            start: "2026-01-20",
            frequency: .monthly,
            patterns: [.dayOfMonth(15), .dayOfMonth(30)]
        )
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-01-20") == "2026-01-30")
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-02-01") == "2026-02-15")
    }

    @Test func monthlyNthAndLastWeekday() throws {
        let monthly = try recurrence(
            start: "2026-01-01",
            frequency: .monthly,
            patterns: [
                .weekday(.friday, ordinal: 2),
                .weekday(.monday, ordinal: -1)
            ]
        )
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-02-01") == "2026-02-09")
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-02-10") == "2026-02-23")
    }

    @Test func monthEndAndLeapDay() throws {
        let monthEnd = try recurrence(
            start: "2026-01-01",
            frequency: .monthly,
            patterns: [.dayOfMonth(-1)]
        )
        let leapDay = try recurrence(start: "2024-02-29", frequency: .yearly)
        #expect(try monthEnd.nextOccurrence(onOrAfter: "2026-02-01") == "2026-02-28")
        #expect(try leapDay.nextOccurrence(onOrAfter: "2025-01-01") == "2028-02-29")
    }

    @Test func yearly() throws {
        let yearly = try recurrence(start: "2024-11-15", frequency: .yearly, interval: 2)
        #expect(try yearly.nextOccurrence(onOrAfter: "2025-01-01") == "2026-11-15")
    }

    @Test func weekendBeforeAfter() throws {
        let after = try recurrence(
            start: "2026-09-05",
            frequency: .weekly,
            skipWeekend: true,
            adjustment: .after
        )
        let before = try recurrence(
            start: "2026-09-05",
            frequency: .weekly,
            skipWeekend: true,
            adjustment: .before
        )
        #expect(try after.nextOccurrence(onOrAfter: "2026-09-05") == "2026-09-07")
        #expect(try before.nextOccurrence(onOrAfter: "2026-09-01") == "2026-09-04")
        #expect(try before.nextOccurrence(onOrAfter: "2026-09-05") == "2026-09-04")
        #expect(try after.nextOccurrence(onOrAfter: "2026-09-07") == "2026-09-14")
    }

    @Test func endAfterOccurrences() throws {
        let limited = try recurrence(
            start: "2026-09-01",
            frequency: .weekly,
            ending: .afterOccurrences(3)
        )
        #expect(try limited.nextOccurrence(onOrAfter: "2026-09-15") == "2026-09-15")
        #expect(try limited.nextOccurrence(onOrAfter: "2026-09-16") == nil)
    }

    @Test func endOnDate() throws {
        let limited = try recurrence(
            start: "2026-09-01",
            frequency: .daily,
            interval: 2,
            ending: .onDate("2026-09-05")
        )
        #expect(try limited.nextOccurrence(onOrAfter: "2026-09-05") == "2026-09-05")
        #expect(try limited.nextOccurrence(onOrAfter: "2026-09-06") == nil)
    }

    @Test func exhaustedRecurrence() throws {
        let exhausted = try recurrence(
            start: "2026-09-01",
            frequency: .daily,
            ending: .afterOccurrences(1)
        )
        #expect(try exhausted.nextOccurrence(onOrAfter: "2026-09-02") == nil)
    }

    @Test func malformedNumericConfigurationFailsClosed() {
        let invalidIntervals: [RuleJSONValue] = [
            .number(0),
            .number(1.5),
            .number(Double.greatestFiniteMagnitude)
        ]
        for interval in invalidIntervals {
            #expect(throws: ActualScheduleRecurrenceError.invalidInterval) {
                _ = try ScheduleRuleProjection.recurrence(
                    from: .object([
                        "start": .string("2026-09-01"),
                        "frequency": .string("daily"),
                        "interval": interval
                    ])
                )
            }
        }
        #expect(throws: ActualScheduleRecurrenceError.invalidSkipWeekend) {
            _ = try ScheduleRuleProjection.recurrence(
                from: .object([
                    "start": .string("2026-09-01"),
                    "frequency": .string("daily"),
                    "skipWeekend": .string("false")
                ])
            )
        }
    }

    @Test func oversizedCustomUpcomingWindowFallsBackWithoutOverflowing() {
        #expect(
            ScheduleUpcomingLength.days(
                for: "\(Int.max)-week",
                today: "2026-09-27"
            ) == 7
        )
    }

    @Test func endCountAppliesToEachActualMonthlyPatternRule() throws {
        let limited = try recurrence(
            start: "2026-01-01",
            frequency: .monthly,
            patterns: [
                .dayOfMonth(1),
                .dayOfMonth(2),
                .dayOfMonth(3),
                .weekday(.monday, ordinal: -1)
            ],
            ending: .afterOccurrences(2)
        )
        #expect(try limited.nextOccurrence(onOrAfter: "2026-01-03") == "2026-01-26")
        #expect(try limited.nextOccurrence(onOrAfter: "2026-01-27") == "2026-02-23")
        #expect(try limited.nextOccurrence(onOrAfter: "2026-02-24") == nil)
    }

    private func recurrence(
        start: String,
        frequency: ActualScheduleFrequency,
        interval: Int = 1,
        patterns: [ActualSchedulePattern] = [],
        skipWeekend: Bool = false,
        adjustment: ActualScheduleWeekendAdjustment = .after,
        ending: ActualScheduleEnding = .never,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> ActualScheduleRecurrence {
        try ActualScheduleRecurrence(
            startDayID: start,
            frequency: frequency,
            interval: interval,
            patterns: patterns,
            skipWeekend: skipWeekend,
            weekendAdjustment: adjustment,
            ending: ending,
            calendar: calendar
        )
    }
}
