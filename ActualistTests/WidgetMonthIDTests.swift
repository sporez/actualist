import Foundation
import Testing
@testable import Actualist

struct WidgetMonthIDTests {
    @Test func formatsGregorianBudgetMonthAndValidatesCanonicalIDs() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))!

        #expect(WidgetMonthID.current(now: date, calendar: calendar) == "2026-09")
        #expect(WidgetMonthID.isCanonical("2026-09"))
        #expect(!WidgetMonthID.isCanonical("2026-9"))
        #expect(!WidgetMonthID.isCanonical("2026-13"))
    }

    @Test func schedulesRefreshJustAfterNextGregorianMonthBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))
        )
        let boundary = WidgetMonthID.nextBoundary(after: date)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: boundary)

        #expect(parts.year == 2026)
        #expect(parts.month == 10)
        #expect(parts.day == 1)
        #expect(parts.hour == 0)
        #expect(parts.minute == 1)
    }
}
