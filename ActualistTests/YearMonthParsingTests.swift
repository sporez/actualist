import Foundation
import Testing
@testable import Actualist

@Suite("YearMonth parsing")
struct YearMonthParsingTests {
    @Test func actualMonthValueRejectsOutOfRangeMonthsAndYears() {
        for bad in ["2026-13", "2026-00", "202613", "0100-05", "abcd-ef", "2026-1", "+12345"] {
            #expect(throws: LocalFirstError.self, "\(bad)") {
                _ = try BudgetDatabase.actualMonthValue(bad)
            }
        }
        #expect((try? BudgetDatabase.actualMonthValue("2026-07")) == 202607)
        #expect((try? BudgetDatabase.actualMonthValue(" 202612 ")) == 202612)
    }

    @Test func parsingKeepsEveryAcceptedShape() {
        let expected: [String: String] = [
            "2026-07": "2026-07",
            "2026/07": "2026-07",
            "2026.07": "2026-07",
            "2026-7": "2026-07",
            "2026/08/15": "2026-08",
            "2026-09-03T10:00": "2026-09",
            "202606": "2026-06",
            "20260615": "2026-06",
            "  2026-07  ": "2026-07"
        ]
        for (input, canonical) in expected {
            #expect(YearMonth.canonicalID(input) == canonical, "\(input)")
        }
    }

    @Test func parsingRejectsInvalidMonthAndYearValues() {
        for bad in ["2026-13", "2026/00", "1899-12", "10000-01", "", "not-a-month", "2026"] {
            #expect(YearMonth.canonicalID(bad) == nil, "\(bad)")
        }
        #expect(YearMonth.canonicalID(nil) == nil)
        #expect(YearMonth(year: 2026, month: 12)?.rawValue == "2026-12")
        #expect(YearMonth(year: 2026, month: 13) == nil)
    }

    @Test func navigationPresentationUsesTheSameParser() throws {
        let month = try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: 0, hiddenCategoryBalance: 0, lastMonthOverspent: 0
        )
        let loaded = LoadedBudgetMonth(
            availableMonths: ["2026.08", "2026-13", "202607"],
            selectedMonth: "2026-06",
            month: month,
            alerts: []
        )
        let ids = BudgetMonthNavigationPresentation.pickerMonths(for: loaded)
        #expect(ids.contains("2026-07"))
        #expect(ids.contains("2026-08"))
        #expect(ids.contains("2026-06"))
        #expect(!ids.contains { $0.hasPrefix("2026-13") })
    }

    @Test func addingMonthsRollsTheYearAndRejectsLeavingTheValidRange() {
        let rows: [(String, Int, String?)] = [
            ("2026-12", 1, "2027-01"), ("2026-01", -1, "2025-12"),
            ("2026-06", 13, "2027-07"), ("2026-06", -25, "2024-05"),
            ("2026-06", 0, "2026-06"), ("9999-12", 1, nil), ("1900-01", -1, nil),
        ]
        for (month, offset, expected) in rows {
            #expect(YearMonth(rawValue: month).adding(months: offset)?.rawValue == expected, "\(month) \(offset)")
        }
        #expect(YearMonth(rawValue: "2026-13").adding(months: 0) == nil)
        #expect(YearMonth(rawValue: "bad").adding(months: 1) == nil)
    }

    @Test func shiftedIDKeepsUnvalidatedRollAndReturnsUnparseableInput() {
        #expect(YearMonth.shiftedID("2026-13", by: 1) == "2027-02")
        #expect(YearMonth.shiftedID("2026-00", by: 0) == "2025-12")
        #expect(YearMonth.shiftedID("a-2026-01", by: 1) == "a-2026-01")
        #expect(YearMonth.shiftedID("a-2026-01", by: 1, ignoringNonNumericParts: true) == "2026-02")
        #expect(YearMonth.shiftedID("2026-02-03", by: 1, ignoringNonNumericParts: true) == "2026-02-03")
    }
}

extension LocalFirstActualStoreTests {
    @Test func carryoverFanOutRejectsAnUnboundedMonthRange() async throws {
        let store = try await makeOpenedWritableStore()
        let database = try store.requireDatabase(for: "group-1")
        var builder = LocalFirstSyncMessageBuilder()

        await #expect(throws: LocalFirstError.self) {
            _ = try await database.categoryCarryoverMessages(
                categoryID: "utilities",
                carryover: true,
                startMonth: "2026-07",
                throughMonth: "9999-12",
                builder: &builder
            )
        }
    }
}
