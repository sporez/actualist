import Foundation
import Testing
@testable import Actualist

@Suite("Actual schedule recurrence")
struct ActualScheduleRecurrenceTests {
    @Test func oneTimeDateIsRepresentedOutsideRecurrence() {
        let rule = ScheduleDateRule.oneTime(dayID: "2026-09-30", operation: "is")
        #expect(rule.recurrence == nil)
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
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-02-01") == "2026-02-13")
        #expect(try monthly.nextOccurrence(onOrAfter: "2026-02-14") == "2026-02-23")
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

    @Test func lastOccurrenceOfCountAndDateEndings() throws {
        #expect(try recurrence(start: "2026-09-01", frequency: .weekly, ending: .afterOccurrences(3))
            .lastOccurrence() == "2026-09-15")
        #expect(try recurrence(start: "2026-09-01", frequency: .daily, interval: 2, ending: .onDate("2026-09-06"))
            .lastOccurrence() == "2026-09-05")
        // February has no 31st, so the third occurrence is in May.
        #expect(try recurrence(start: "2026-01-31", frequency: .monthly, ending: .afterOccurrences(3))
            .lastOccurrence() == "2026-05-31")
        #expect(try recurrence(start: "2024-02-29", frequency: .yearly, ending: .onDate("2027-12-31"))
            .lastOccurrence() == "2024-02-29")
        #expect(try recurrence(start: "2026-09-01", frequency: .weekly).lastOccurrence() == nil)
    }

    @Test func lastOccurrenceEndBeforeStartIsNilAndZeroCountIsRejected() throws {
        #expect(try recurrence(start: "2026-09-10", frequency: .daily, ending: .onDate("2026-09-01"))
            .lastOccurrence() == nil)
        #expect(throws: ActualScheduleRecurrenceError.invalidEnding) {
            try recurrence(start: "2026-09-01", frequency: .daily, ending: .afterOccurrences(0))
        }
    }

    @Test func lastOccurrenceAppliesWeekendSolveAfterChoosingTheNaturalDate() throws {
        // 2026-09-05 is a Saturday; the second weekly occurrence is Saturday 2026-09-12.
        let after = try recurrence(
            start: "2026-09-05", frequency: .weekly, skipWeekend: true,
            adjustment: .after, ending: .afterOccurrences(2)
        )
        let before = try recurrence(
            start: "2026-09-05", frequency: .weekly, skipWeekend: true,
            adjustment: .before, ending: .afterOccurrences(2)
        )
        #expect(try after.lastOccurrence() == "2026-09-14")
        #expect(try before.lastOccurrence() == "2026-09-11")
        #expect(try after.lastOccurrence(applyWeekendAdjustment: false) == "2026-09-12")
    }

    @Test func lastOccurrenceOfSplitMonthlyRulesUsesEachFamilyCount() throws {
        let split = try recurrence(
            start: "2026-09-01",
            frequency: .monthly,
            patterns: [.dayOfMonth(1), .weekday(.friday, ordinal: 1)],
            ending: .afterOccurrences(3)
        )
        // Day-1 family: Sep 1, Oct 1, Nov 1. First-Friday family: Sep 4, Oct 2, Nov 6.
        #expect(try split.lastOccurrence() == "2026-11-06")
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
        #expect(throws: ActualScheduleRecurrenceError.invalidWeekendAdjustment) {
            _ = try ScheduleRuleProjection.recurrence(
                from: .object([
                    "start": .string("2026-09-01"),
                    "frequency": .string("daily"),
                    "skipWeekend": .bool(true)
                ])
            )
        }
        #expect(throws: ActualScheduleRecurrenceError.invalidWeekendAdjustment) {
            _ = try ScheduleRuleProjection.recurrence(
                from: .object([
                    "start": .string("2026-09-01"),
                    "frequency": .string("daily"),
                    "skipWeekend": .bool(true),
                    "weekendSolveMode": .string("nearest")
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

    @Test func monthlySearchJumpsToTheSupportedCalendarUpperBound() throws {
        let monthly = try recurrence(
            start: "0001-01-31",
            frequency: .monthly,
            patterns: [.dayOfMonth(31)]
        )
        #expect(try monthly.nextOccurrence(onOrAfter: "9999-12-01") == "9999-12-31")
    }

    @Test func intervalsBeyondTheSupportedCalendarReturnNoOccurrence() throws {
        let monthly = try recurrence(
            start: "0001-01-31",
            frequency: .monthly,
            interval: .max
        )
        let yearly = try recurrence(
            start: "0001-01-31",
            frequency: .yearly,
            interval: .max
        )

        #expect(try monthly.nextOccurrence(onOrAfter: "9999-12-01") == nil)
        #expect(try yearly.nextOccurrence(onOrAfter: "9999-12-01") == nil)
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
