import Foundation
@testable import Actualist

/// The device-local calendar day, as an Actual `yyyy-MM-dd` id. Schedule tests
/// that must agree with production's local "today" share this one definition.
enum TestLocalDay {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func dayID(_ date: Date = Date()) -> String {
        ActualScheduleRecurrence.dayID(from: date, calendar: calendar)
    }

    static func today() -> String { dayID() }
}
