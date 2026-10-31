import Foundation
import Testing
@testable import Actualist

struct WidgetMonthProgressTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func measuresSpendingAgainstBudgetAndTheCalendar() throws {
        let progress = try #require(
            WidgetMonthProgress(spent: 3_000, budgeted: 6_000, income: 9_000, now: date(9, 15), calendar: calendar)
        )
        #expect(progress.base == .budgeted)
        #expect(progress.spending.barFraction == 0.5)
        #expect(!progress.spending.isOver)
        #expect(progress.monthFraction == 0.5)
        #expect(progress.daysLeft == 15)
        #expect(progress.daysLeftText == "15 days left")
    }

    @Test func spendingShareNeedsAPositiveBudget() throws {
        #expect(WidgetSpendingShare(spent: 100, budget: 0) == nil)
        #expect(WidgetSpendingShare(spent: 100, budget: -5) == nil)
        let half = try #require(WidgetSpendingShare(spent: 500, budget: 1_000))
        #expect(half.share == 0.5)
        #expect(half.text == 0.5.formatted(.percent.precision(.fractionLength(0))))
    }

    @Test func fallsBackToIncomeWithoutABudget() throws {
        let progress = try #require(
            WidgetMonthProgress(spent: 2_500, budgeted: 0, income: 10_000, now: date(9, 15), calendar: calendar)
        )
        #expect(progress.base == .income)
        #expect(progress.spending.barFraction == 0.25)
    }

    @Test func hasNoScaleWithoutABudgetOrIncome() {
        #expect(WidgetMonthProgress(spent: 500, budgeted: 0, income: 0, now: date(9, 15), calendar: calendar) == nil)
        #expect(WidgetMonthProgress(spent: 500, budgeted: -100, income: -100, now: date(9, 15), calendar: calendar) == nil)
    }

    @Test func clampsOverspendingAndRefunds() throws {
        let over = try #require(
            WidgetMonthProgress(spent: 7_000, budgeted: 6_000, income: 0, now: date(9, 15), calendar: calendar)
        )
        #expect(over.spending.barFraction == 1)
        #expect(over.spending.share > 1)
        #expect(over.spending.isOver)

        let exact = try #require(
            WidgetMonthProgress(spent: 6_000, budgeted: 6_000, income: 0, now: date(9, 15), calendar: calendar)
        )
        #expect(exact.spending.barFraction == 1)
        #expect(!exact.spending.isOver)

        let refunds = try #require(
            WidgetMonthProgress(spent: -400, budgeted: 6_000, income: 0, now: date(9, 15), calendar: calendar)
        )
        #expect(refunds.spending.share == 0)
        #expect(refunds.spending.barFraction == 0)
        #expect(!refunds.spending.isOver)
    }

    @Test(arguments: [(29, 1, "1 day left"), (30, 0, "Last day"), (28, 2, "2 days left")])
    func describesTheEndOfTheMonth(day: Int, daysLeft: Int, text: String) throws {
        let progress = try #require(
            WidgetMonthProgress(spent: 0, budgeted: 100, income: 0, now: date(9, day), calendar: calendar)
        )
        #expect(progress.daysLeft == daysLeft)
        #expect(progress.daysLeftText == text)
    }

    @Test func usesTheCalendarLengthOfTheMonth() throws {
        let february = try #require(
            WidgetMonthProgress(spent: 0, budgeted: 100, income: 0, now: date(2, 14), calendar: calendar)
        )
        #expect(february.monthFraction == 0.5)
        #expect(february.daysLeft == 14)
    }

    @Test func schedulesEachRemainingMidnightOfTheMonth() {
        let boundaries = WidgetMonthID.dailyBoundaries(after: date(9, 28, hour: 9), calendar: calendar)
        #expect(boundaries == [date(9, 29, hour: 0), date(9, 30, hour: 0)])
        #expect(WidgetMonthID.dailyBoundaries(after: date(9, 30, hour: 9), calendar: calendar).isEmpty)
    }

    @Test func doesNotRepeatTheCurrentMidnight() {
        let boundaries = WidgetMonthID.dailyBoundaries(after: date(9, 29, hour: 0), calendar: calendar)
        #expect(boundaries == [date(9, 30, hour: 0)])
    }

    @Test func namesCanonicalMonthsOnly() {
        var english = calendar
        english.locale = Locale(identifier: "en_US")
        #expect(WidgetMonthID.displayName("2026-10", calendar: english) == "October")
        #expect(WidgetMonthID.displayName("2026-13", calendar: english) == nil)
        #expect(WidgetMonthID.displayName("October", calendar: english) == nil)
    }

    @Test func defaultCalendarNamesMonthsRatherThanNumberingThem() throws {
        let name = try #require(WidgetMonthID.displayName("2026-10"))
        #expect(!name.hasPrefix("M1"))
    }
}
