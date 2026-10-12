import Foundation
import Testing
@testable import Actualist

/// Actual creates budget months through a year past the current month, so a carryover write applies through
/// `currentMonth + 12` (never a start month beyond it).
@Suite("Category carryover horizon")
@MainActor
struct CategoryCarryoverHorizonTests {
    private func date(_ year: Int, _ month: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: 15))!
    }

    @Test func horizonIsTwelveMonthsPastTheCurrentMonth() {
        #expect(LocalFirstActualStore.categoryCarryoverHorizonMonth(startMonth: "2026-01", now: date(2026, 10)) == "2027-10")
    }

    @Test func horizonRollsThroughTheYearBoundary() {
        #expect(LocalFirstActualStore.categoryCarryoverHorizonMonth(startMonth: "2026-01", now: date(2026, 12)) == "2027-12")
        #expect(LocalFirstActualStore.categoryCarryoverHorizonMonth(startMonth: "2026-01", now: date(2026, 1)) == "2027-01")
    }

    @Test func startMonthPastTheHorizonIsKept() {
        #expect(LocalFirstActualStore.categoryCarryoverHorizonMonth(startMonth: "2029-03", now: date(2026, 10)) == "2029-03")
    }
}
