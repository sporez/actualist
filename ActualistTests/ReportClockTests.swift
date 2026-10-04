import Foundation
import Testing
@testable import Actualist

struct ReportClockTests {
    @Test func pinnedDateParsesTheLaunchFlagAsTheSameCalendarDay() throws {
        let pinned = try #require(ReportClock.pinnedDate(from: ["app", "-actualist-report-today", "2026-08-31"]))
        #expect(ReportCalendar.dayID(for: pinned, calendar: ReportCalendar.gregorianUTC) == "2026-08-31")
        #expect(ReportCalendar.dayID(for: pinned, calendar: ReportCalendar.gregorianLocal) == "2026-08-31")
    }

    @Test func missingOrMalformedFlagLeavesTheClockUnpinned() {
        #expect(ReportClock.pinnedDate(from: ["app"]) == nil)
        #expect(ReportClock.pinnedDate(from: ["-actualist-report-today"]) == nil)
        #expect(ReportClock.pinnedDate(from: ["-actualist-report-today", "tomorrow"]) == nil)
    }

    @Test func pinnedClockDrivesTheRangePresets() throws {
        let pinned = try #require(ReportClock.pinnedDate(from: ["-actualist-report-today", "2026-08-31"]))
        let range = try #require(ReportExplorerRangePreset.threeMonths.range(through: pinned))
        #expect(range.endDay == "2026-08-31")
        #expect(range.startDay == "2026-06-01")
    }
}
