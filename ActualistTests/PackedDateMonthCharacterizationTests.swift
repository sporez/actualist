import Foundation
import Testing
@testable import Actualist

/// Pins what the packed-date and packed-month helpers return today, including
/// their unvalidated and odd outputs, so consolidating them cannot change a
/// call site's value or failure value. Expectations come from unchanged code.
@MainActor
struct PackedDateMonthCharacterizationTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeDatabase() throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: try fixtures.makeSQLiteFixture(), localNodeID: "node1")
    }

    @Test func packedDateFromISOStripsDashesAndFailsToZero() {
        let rows: [(String?, Int)] = [
            ("2026-12-31", 20261231), ("2026-01-01", 20260101), ("2026-02-31", 20260231),
            ("2026-1-5", 202615), ("20261231", 20261231), ("", 0), (nil, 0), ("-", 0),
            ("abc", 0), (" 2026-12-31", 0), ("2026-12-31T00:00", 0), ("--2026", 2026),
        ]
        for (text, expected) in rows {
            #expect(BudgetDatabase.packedDate(fromISO: text) == expected, "\(text ?? "nil")")
        }
    }

    @Test func isoDateStringFormatsWithoutValidation() {
        let rows: [(Int, String)] = [
            (20261231, "2026-12-31"), (20260101, "2026-01-01"), (0, "0000-00-00"),
            (-5, "0000-00--5"), (2026123, "0202-61-23"), (202612310, "20261-23-10"),
            (20260231, "2026-02-31"),
        ]
        for (packed, expected) in rows {
            #expect(BudgetDatabase.isoDateString(fromPacked: packed) == expected, "\(packed)")
        }
    }

    @Test func schemaMonthIntStripsDashesAndFailsToZero() async throws {
        let database = try makeDatabase()
        let rows: [(String, Int)] = [
            ("2026-01", 202601), ("2026-1", 20261), ("202601", 202601), ("2026-13", 202613),
            ("2026-01-15", 20260115), ("", 0), ("abc", 0),
        ]
        for (text, expected) in rows {
            #expect(await database.monthInt(text) == expected, "\(text)")
        }
    }

    @Test func schemaMonthIDFormatsWithoutValidation() async throws {
        let database = try makeDatabase()
        let rows: [(Int, String)] = [
            (202601, "2026-01"), (202613, "2026-13"), (0, "0000-00"), (-5, "0000--5"), (20261, "0202-61"),
        ]
        for (month, expected) in rows {
            #expect(await database.monthID(month) == expected, "\(month)")
        }
    }

    @Test func schemaShiftedMonthRollsWithoutValidation() async throws {
        let database = try makeDatabase()
        let rows: [(Int, Int, Int)] = [
            (202612, 1, 202701), (202601, -1, 202512), (202606, 13, 202707), (202606, -13, 202505),
            (202601, 0, 202601), (202613, 0, 202701), (202600, 0, 202512), (0, 0, 0),
            (202601, 12, 202701), (202601, -12, 202501),
        ]
        for (month, offset, expected) in rows {
            #expect(await database.shiftedMonth(month, by: offset) == expected, "\(month) \(offset)")
        }
    }

    @Test func schemaNextMonthIncrementsWithoutValidation() async throws {
        let database = try makeDatabase()
        let rows: [(Int, Int)] = [
            (202612, 202701), (202601, 202602), (202613, 202614), (202600, 202601), (0, 1),
        ]
        for (month, expected) in rows {
            #expect(await database.nextMonth(after: month) == expected, "\(month)")
        }
    }

    @Test func templateCalendarShiftedMonthValidatesAndThrowsOutsideRange() throws {
        let rows: [(Int, Int, Int)] = [
            (202612, 1, 202701), (202601, -1, 202512), (202606, 13, 202707), (202606, -13, 202505),
            (202601, 0, 202601), (999912, 0, 999912), (101, 0, 101), (202601, 12, 202701),
        ]
        for (month, offset, expected) in rows {
            #expect(try BudgetTemplateCalendar.shiftedMonth(month, by: offset) == expected, "\(month) \(offset)")
        }
        let failing: [(Int, Int)] = [
            (999912, 1), (101, -1), (202613, 0), (202600, 0), (0, 0), (202601, Int.max), (202601, Int.min),
        ]
        for (month, offset) in failing {
            #expect(throws: (any Error).self, "\(month) \(offset)") {
                try BudgetTemplateCalendar.shiftedMonth(month, by: offset)
            }
        }
    }

    @Test func templateCalendarMonthIDFormatsWithoutValidation() {
        #expect(BudgetTemplateCalendar.monthID(202601) == "2026-01")
        #expect(BudgetTemplateCalendar.monthID(202613) == "2026-13")
        #expect(BudgetTemplateCalendar.monthID(0) == "0000-00")
    }
}
