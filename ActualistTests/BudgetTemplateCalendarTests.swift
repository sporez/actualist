import Foundation
import Testing
@testable import Actualist

@Suite("Budget template calendar")
struct BudgetTemplateCalendarTests {
    @Test func validatedDateRoundTripsThroughDayIDAtLocalNoon() throws {
        let date = try #require(BudgetTemplateCalendar.validatedDate("2026-07-15"))
        #expect(BudgetTemplateCalendar.dayID(from: date) == "2026-07-15")
        #expect(BudgetTemplateCalendar.gregorian.component(.hour, from: date) == 12)
    }

    @Test func springDSTTransitionDateKeepsItsDayID() throws {
        let date = try #require(BudgetTemplateCalendar.validatedDate("2026-03-08"))
        #expect(BudgetTemplateCalendar.dayID(from: date) == "2026-03-08")
        #expect(BudgetTemplateCalendar.gregorian.component(.hour, from: date) == 12)
    }

    @Test func fallDSTTransitionDateKeepsItsDayID() throws {
        let date = try #require(BudgetTemplateCalendar.validatedDate("2026-11-01"))
        #expect(BudgetTemplateCalendar.dayID(from: date) == "2026-11-01")
        #expect(BudgetTemplateCalendar.gregorian.component(.hour, from: date) == 12)
    }

    @Test func periodicDaySteppingAcrossDSTKeepsStableDayIDs() throws {
        let marchStart = try BudgetTemplateCalendar.monthStartDate(202603)
        let aprilStart = try BudgetTemplateCalendar.nextMonthStartDate(202603)
        #expect(BudgetTemplateCalendar.dayID(from: marchStart) == "2026-03-01")
        #expect(BudgetTemplateCalendar.dayID(from: aprilStart) == "2026-04-01")

        let count = try BudgetTemplateCalendar.periodicOccurrenceCount(
            startingAt: marchStart,
            monthStart: marchStart,
            nextMonthStart: aprilStart,
            interval: 1,
            period: "day"
        )
        #expect(count == 31)

        let weekCount = try BudgetTemplateCalendar.periodicOccurrenceCount(
            startingAt: try #require(BudgetTemplateCalendar.validatedDate("2026-03-01")),
            monthStart: marchStart,
            nextMonthStart: aprilStart,
            interval: 1,
            period: "week"
        )
        #expect(weekCount == 5)
    }

    @Test func periodicWeekSteppingAcrossFallDSTKeepsStableDayIDs() throws {
        let novemberStart = try BudgetTemplateCalendar.monthStartDate(202611)
        let decemberStart = try BudgetTemplateCalendar.nextMonthStartDate(202611)
        #expect(BudgetTemplateCalendar.dayID(from: novemberStart) == "2026-11-01")
        #expect(BudgetTemplateCalendar.dayID(from: decemberStart) == "2026-12-01")

        let start = try #require(BudgetTemplateCalendar.validatedDate("2026-10-25"))
        let count = try BudgetTemplateCalendar.periodicOccurrenceCount(
            startingAt: start,
            monthStart: novemberStart,
            nextMonthStart: decemberStart,
            interval: 1,
            period: "week"
        )
        // 25 Oct, 1 Nov, 8 Nov, 15 Nov, 22 Nov, 29 Nov — five in November.
        #expect(count == 5)
        #expect(try BudgetTemplateCalendar.shiftedPeriodicDate("2026-10-25", by: 1, period: "week") == "2026-11-01")
        #expect(try BudgetTemplateCalendar.shiftedPeriodicDate("2026-11-01", by: 1, period: "week") == "2026-11-08")
    }

    @Test func monthBoundaryAroundDSTKeepsStableMonthStartIDs() throws {
        let march = try BudgetTemplateCalendar.monthStartDate(202603)
        let april = try BudgetTemplateCalendar.nextMonthStartDate(202603)
        let november = try BudgetTemplateCalendar.monthStartDate(202611)
        let december = try BudgetTemplateCalendar.nextMonthStartDate(202611)
        #expect(BudgetTemplateCalendar.dayID(from: march) == "2026-03-01")
        #expect(BudgetTemplateCalendar.dayID(from: april) == "2026-04-01")
        #expect(BudgetTemplateCalendar.dayID(from: november) == "2026-11-01")
        #expect(BudgetTemplateCalendar.dayID(from: december) == "2026-12-01")
        #expect(try BudgetTemplateCalendar.daysInMonth(202603) == 31)
        #expect(try BudgetTemplateCalendar.daysInMonth(202611) == 30)
    }
}
