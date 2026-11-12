import Foundation
import Testing
@testable import Actualist

/// Day windows that Actual builds from date strings (`addDays`, `subDays`,
/// `currentDay()` in shared/months.ts) are pure date arithmetic, and "today"
/// is the local day.
struct ActualDayArithmeticParityTests {
    /// 2026-03-15 23:30 UTC: already the 16th in Kiritimati.
    private static let lateUTC = Date(timeIntervalSince1970: 1_773_617_400)
    /// 2026-03-15 05:00 UTC: still the 14th in Pago Pago.
    private static let earlyUTC = Date(timeIntervalSince1970: 1_773_550_800)
    private static let east = TimeZone(identifier: "Pacific/Kiritimati")!
    private static let west = TimeZone(identifier: "Pacific/Pago_Pago")!

    @Test func shiftedDayIDCrossesMonthsYearsAndLeapDays() {
        let rows: [(String, Int, String?)] = [
            ("2026-03-15", 0, "2026-03-15"),
            ("2026-03-01", -1, "2026-02-28"), ("2024-03-01", -1, "2024-02-29"),
            ("2025-12-31", 1, "2026-01-01"), ("2026-01-01", -1, "2025-12-31"),
            ("2026-03-15", 180, "2026-09-11"), ("2026-03-15", -180, "2025-09-16"),
            ("2026-03-15", -84, "2025-12-21"),
            ("2026-02-31", 1, nil), ("2026-3-5", 1, nil), ("", 1, nil), ("junk", 1, nil),
        ]
        for (day, offset, expected) in rows {
            #expect(ActualDateOnly.shiftedDayID(day, byDays: offset) == expected, "\(day) \(offset)")
        }
    }

    @Test func shiftedDayIDIgnoresTheDeviceZoneAcrossDSTChanges() {
        // 2026-03-08 is a US DST change; 2026-10-25 a European one.
        #expect(ActualDateOnly.shiftedDayID("2026-03-07", byDays: 2) == "2026-03-09")
        #expect(ActualDateOnly.shiftedDayID("2026-10-24", byDays: 2) == "2026-10-26")
        #expect(ActualDateOnly.shiftedDayID("2026-10-26", byDays: -2) == "2026-10-24")
    }

    @Test func categoryLearningWindowIs180DaysEitherSideOfTheLocalDay() {
        let utc = BudgetDatabase.categoryLearningWindow(oldestDate: "2026-03-15", now: Self.lateUTC, timeZone: .gmt)
        #expect(utc.lower == "2025-09-16")
        #expect(utc.upper == "2026-09-11")
        let east = BudgetDatabase.categoryLearningWindow(oldestDate: "2026-03-15", now: Self.lateUTC, timeZone: Self.east)
        #expect(east.upper == "2026-09-12")
        let west = BudgetDatabase.categoryLearningWindow(oldestDate: "2026-03-15", now: Self.earlyUTC, timeZone: Self.west)
        #expect(west.upper == "2026-09-10")
        // An unreadable oldest day counts as 1970-01-01.
        let epoch = BudgetDatabase.categoryLearningWindow(oldestDate: "garbage", now: Self.lateUTC, timeZone: .gmt)
        #expect(epoch.lower == "1969-07-05")
    }

    @Test func recentPayeeCutoffIs12WeeksBeforeTheLocalDay() {
        #expect(BudgetDatabase.recentPayeeCutoff(now: Self.lateUTC, timeZone: .gmt) == "2025-12-21")
        #expect(BudgetDatabase.recentPayeeCutoff(now: Self.lateUTC, timeZone: Self.east) == "2025-12-22")
        #expect(BudgetDatabase.recentPayeeCutoff(now: Self.earlyUTC, timeZone: Self.west) == "2025-12-20")
    }
}
