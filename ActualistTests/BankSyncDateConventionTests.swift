import Foundation
import Testing
@testable import Actualist

struct BankSyncDateConventionTests {
    @Test(arguments: [
        ("Pacific/Kiritimati", 14 * 3600),
        ("Pacific/Auckland", 12 * 3600),
        ("UTC", 0),
        ("Etc/GMT+12", -12 * 3600)
    ])
    func dayIDRoundTripsAtLocalNoon(identifier: String, offsetSeconds: Int) throws {
        let zone = try #require(TimeZone(identifier: identifier))
        let fixed = try #require(TimeZone(secondsFromGMT: offsetSeconds))
        for zoneUnderTest in [zone, fixed] {
            let date = try #require(BankSyncAmounts.date(fromDayID: "20260315", timeZone: zoneUnderTest))
            #expect(try BudgetDatabase.actualDateValue(date, timeZone: zoneUnderTest) == 20260315)
            #expect(ActualDateOnly.dayID(from: date, timeZone: zoneUnderTest) == "2026-03-15")
        }
    }

    @Test func rejectsMalformedDayID() {
        #expect(BankSyncAmounts.date(fromDayID: "2026-03-15", timeZone: .gmt) == nil)
        #expect(BankSyncAmounts.date(fromDayID: "20260231", timeZone: .gmt) == nil)
    }
}
