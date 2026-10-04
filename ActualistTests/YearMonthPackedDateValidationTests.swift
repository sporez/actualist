import Foundation
import Testing
@testable import Actualist

/// Phase 6.3: the merge and duplicate planners each validated a packed
/// `YYYYMMDD` before taking its month. They share `YearMonth`'s validator; the
/// verbatim old bodies are the oracle over the boundary inputs.
struct YearMonthPackedDateValidationTests {
    private static func oldMergeMonthID(_ value: Int) -> String? {
        guard value >= 10_101 && value <= 99_991_231 else { return nil }
        let day = value % 100
        let month = (value / 100) % 100
        let year = value / 10_000
        guard (1...12).contains(month), (1...31).contains(day), year > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        let digits = String(format: "%08d", value)
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))"
    }

    private static func oldDuplicateMonthID(_ packedDate: Int) -> String? {
        guard packedDate > 0 else { return nil }
        let year = packedDate / 10_000
        let month = (packedDate / 100) % 100
        let day = packedDate % 100
        guard (1...9_999).contains(year) else { return nil }
        let dateID = String(format: "%04d-%02d-%02d", year, month, day)
        guard ActualDateOnly.date(from: dateID, timeZone: .gmt) != nil else { return nil }
        return String(dateID.prefix(7))
    }

    @Test func sharedValidatorEqualsBothPlannerValidatorsOnBoundaryInputs() {
        var inputs: [Int] = [Int.min, -1, 0, 1, 99, 10_100, 10_101, 10_131, 10_132, 99_991_231, 99_991_232,
                             100_000_000, 100_010_101, Int.max]
        for year in [1, 4, 100, 400, 1_582, 1_583, 1_900, 2_000, 2_023, 2_024, 2_100, 9_998, 9_999] {
            for month in 0...13 {
                for day in [0, 1, 15, 28, 29, 30, 31, 32] { inputs.append(year * 10_000 + month * 100 + day) }
            }
        }
        // Julian-to-Gregorian gap days.
        inputs += (1...16).map { 1_582_1000 + $0 }
        var valid = 0
        for value in inputs {
            let shared = YearMonth(validatingPackedDate: value)?.rawValue
            #expect(shared == Self.oldMergeMonthID(value), "merge \(value)")
            #expect(shared == Self.oldDuplicateMonthID(value), "duplicate \(value)")
            if shared != nil { valid += 1 }
        }
        #expect(valid > 500)
    }
}
