import Foundation
import Testing
@testable import Actualist

/// Pins what each hand-built day/month copy returns today, including its odd
/// leniency, so consolidating them onto `ActualDateOnly` / `YearMonth` cannot
/// change an output. Expectations come from running the unchanged code.
@MainActor
struct DateOwnershipCharacterizationTests {
    private static let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
    private static let minus12 = TimeZone(identifier: "Etc/GMT+12")!
    /// Clocks skip 00:00-01:00 on 2026-09-06, so midnight does not exist there.
    private static let santiago = TimeZone(identifier: "America/Santiago")!

    private static func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        )!
    }

    private static func components(_ date: Date, in zone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour], from: date)
    }

    // MARK: Schedule editor

    @Test func scheduleDayIDUsesTheGivenZoneAcrossOffsetsAndDST() {
        let rows: [(String, TimeZone, String)] = [
            ("2026-03-15T10:30:00Z", .gmt, "2026-03-15"),
            ("2026-03-15T10:30:00Z", Self.kiritimati, "2026-03-16"),
            ("2026-03-15T09:59:59Z", Self.kiritimati, "2026-03-15"),
            ("2026-03-15T10:00:00Z", Self.kiritimati, "2026-03-16"),
            ("2026-03-15T10:30:00Z", Self.minus12, "2026-03-14"),
            ("2026-03-15T11:59:59Z", Self.minus12, "2026-03-14"),
            ("2026-03-15T12:00:00Z", Self.minus12, "2026-03-15"),
            ("2026-09-06T03:59:59Z", Self.santiago, "2026-09-05"),
            ("2026-09-06T04:00:00Z", Self.santiago, "2026-09-06"),
        ]
        for (iso, zone, expected) in rows {
            #expect(ScheduleEditorDraft.dayID(from: Self.instant(iso), timeZone: zone) == expected, "\(iso) \(zone.identifier)")
        }
        let now = Date()
        #expect(ScheduleEditorDraft.dayID(from: now) == ScheduleEditorDraft.dayID(from: now, timeZone: .autoupdatingCurrent))
        #expect(ScheduleEditorDraft.dayID(from: Self.localDate(2026, 3, 15, 0, 0, 30)) == "2026-03-15")
        #expect(ScheduleEditorDraft.dayID(from: Self.localDate(2026, 3, 15, 23, 59, 59)) == "2026-03-15")
    }

    @Test func scheduleDateBuildsLocalNoonAndRollsInvalidDaysForward() {
        for zone in [TimeZone.gmt, Self.kiritimati, Self.minus12, Self.santiago] {
            for dayID in ["2026-03-15", "2026-09-06", "2026-09-05", "2028-02-29"] {
                let date = ScheduleEditorDraft.date(from: dayID, timeZone: zone)
                let parts = Self.components(date, in: zone)
                #expect(parts.hour == 12, "\(dayID) \(zone.identifier)")
                #expect(ScheduleEditorDraft.dayID(from: date, timeZone: zone) == dayID, "\(dayID) \(zone.identifier)")
            }
        }
        let rolled: [(String, String)] = [
            ("2026-02-31", "2026-03-03"),
            ("2026-13-01", "2027-01-01"),
            ("2026-1-5", "2026-01-05"),
            ("a-2026-01-05", "2026-01-05"),
        ]
        for (input, expected) in rolled {
            let date = ScheduleEditorDraft.date(from: input, timeZone: .gmt)
            #expect(ScheduleEditorDraft.dayID(from: date, timeZone: .gmt) == expected, "\(input)")
        }
    }

    @Test func scheduleDateFallsBackToNowOnAnUnparseableDayID() {
        for input in ["", "bad", "2026-01", "2026-01-05-07", "2026-xx-05"] {
            let date = ScheduleEditorDraft.date(from: input, timeZone: .gmt)
            #expect(abs(date.timeIntervalSinceNow) < 60, "\(input)")
        }
    }

    // MARK: Rule editor

    @Test func ruleDayIDUsesTheDeviceZone() {
        for (hour, minute, second) in [(0, 0, 30), (12, 0, 0), (23, 59, 59)] {
            #expect(RuleEditorDraftState.dayID(from: Self.localDate(2026, 3, 15, hour, minute, second)) == "2026-03-15")
        }
        #expect(RuleEditorDraftState.dateValue(from: Self.localDate(2026, 12, 31, 23, 59, 59)) == .string("2026-12-31"))
    }

    @Test func ruleDateSelectionIsStrictAndBuildsLocalNoon() throws {
        for dayID in ["2026-03-15", "2028-02-29", "0001-01-01", "9999-12-31"] {
            let date = try #require(RuleEditorDraftState.dateSelection(.string(dayID)), "\(dayID)")
            #expect(Self.components(date, in: .current).hour == 12, "\(dayID)")
            #expect(RuleEditorDraftState.dayID(from: date) == dayID, "\(dayID)")
        }
        for bad in ["2026-02-31", "2026-13-01", "", "2026-1-5", "2026-03", "2026", "2026-03-15x", "0000-01-01", "2026-+1-05", "a-2026-01-05", "2026-03-15-"] {
            #expect(RuleEditorDraftState.dateSelection(.string(bad)) == nil, "\(bad)")
        }
        #expect(RuleEditorDraftState.dateSelection(.number(20260315)) == nil)
        #expect(RuleEditorDraftState.dateSelection(.null) == nil)
    }

    @Test func ruleConditionDateValidationRoundTripsThroughUTC() {
        let accepted = ["2026-03-15", "2024-02-29", "0001-01-01", "9999-12-31", "2026-03", "2026"]
        let rejected = ["2026-02-31", "2026-02-29", "2026-13-01", "2026-1-5", "2026-3", "0000-01-01", "2026-+1-05", "", "2026-03-15-"]
        for value in accepted {
            #expect(RuleCondition(field: "date", operation: "is", value: .string(value)).canRoundTripAndEvaluate, "\(value)")
        }
        for value in rejected {
            #expect(!RuleCondition(field: "date", operation: "is", value: .string(value)).canRoundTripAndEvaluate, "\(value)")
        }
    }

    // MARK: Transaction filter

    @Test func filterDayAndDateUseTheDeviceZoneAtLocalNoon() throws {
        for (hour, minute, second) in [(0, 0, 30), (12, 0, 0), (23, 59, 59)] {
            var applied: [TransactionQueryCondition] = []
            let workflow = TransactionFilterWorkflow(onApply: { conditions, _ in applied = conditions })
            workflow.includesDate = true
            workflow.date = Self.localDate(2026, 3, 15, hour, minute, second)
            #expect(workflow.apply())
            #expect(applied.contains(.date(TransactionQueryDateCondition(
                operation: workflow.dateOperation,
                day: try #require(TransactionQueryDay(rawValue: "2026-03-15"))
            ))))
        }
        for dayID in ["2026-03-15", "2028-02-29", "2026-01-01", "2026-12-31"] {
            let day = try #require(TransactionQueryDay(rawValue: dayID))
            let workflow = TransactionFilterWorkflow(
                conditions: [.date(TransactionQueryDateCondition(operation: .isOnOrAfter, day: day))],
                join: .and
            )
            let parts = Self.components(workflow.date, in: .current)
            let expected = dayID.split(separator: "-").compactMap { Int($0) }
            #expect([parts.year, parts.month, parts.day] == expected, "\(dayID)")
            #expect(parts.hour == 12, "\(dayID)")
        }
    }

    // MARK: Reports

    @Test func reportCalendarParsesDayIDsLeniently() throws {
        let rows: [(String, String?)] = [
            ("2026-03-15", "2026-03-15"),
            ("2026-02-31", "2026-03-03"),
            ("2026-13-01", "2027-01-01"),
            ("2026-00-10", "2025-12-10"),
            ("2026-1-5", "2026-01-05"),
            ("2026-01-05-", "2026-01-05"),
            ("+2026-01-05", "2026-01-05"),
            ("0000-05-01", "0001-05-01"),
            ("0001-01-01", "0001-01-01"),
            ("10000-01-01", "10000-01-01"),
            ("", nil),
            ("a-2026-01-05", nil),
            ("2026-01", nil),
            ("bad", nil),
        ]
        for (input, expected) in rows {
            let date = ReportCalendar.date(fromDayID: input)
            #expect(date.map { ReportCalendar.dayID(for: $0) } == expected, "\(input)")
        }
        let march15 = try #require(ReportCalendar.date(fromDayID: "2026-03-15"))
        #expect(march15.timeIntervalSince1970 == 1_773_532_800)
    }

    private static let monthShiftRows: [(String, Int, String)] = [
        ("2026-12", 1, "2027-01"), ("2026-01", -1, "2025-12"),
        ("2026-06", 13, "2027-07"), ("2026-06", -13, "2025-05"),
        ("2026-06", 25, "2028-07"), ("2026-06", -25, "2024-05"),
        ("2026-06", 0, "2026-06"), ("2026-1", 1, "2026-02"),
        ("2026-13", 0, "2027-01"), ("2026-13", 1, "2027-02"),
        ("2026-00", 0, "2025-12"), ("2026-00", -1, "2025-11"),
        ("0000-05", 0, "0001-05"), ("0001-01", -1, "0001-12"),
        ("0001-01", -2, "0001-11"), ("0000-01", 3, "0001-04"),
        ("9999-12", 1, "10000-01"), ("2026-0013", 0, "2027-01"),
        ("-2026-01", 0, "2026-01"),
        // Unparseable input comes back unchanged.
        ("", 1, ""), ("bad", 3, "bad"), ("2026-02-03", 1, "2026-02-03"), ("2026", 2, "2026"),
    ]

    @Test func reportShiftedMonthRollsTheYearAndKeepsUnparseableInput() {
        for (month, offset, expected) in Self.monthShiftRows {
            #expect(ReportCalendar.shiftedMonth(month, by: offset) == expected, "\(month) \(offset)")
        }
        #expect(ReportCalendar.shiftedMonth("a-2026-01", by: 1) == "a-2026-01")
        #expect(ReportCalendar.monthIDs(from: "2026-11", through: "2027-02") == ["2026-11", "2026-12", "2027-01", "2027-02"])
        #expect(ReportCalendar.shiftedDay("2026-03-31", byMonths: 1) == "2026-04-30")
        #expect(ReportCalendar.shiftedDay("2026-01-31", byMonths: -2) == "2025-11-30")
    }

    // MARK: Budget viewport

    @Test func viewportMonthOffsetMatchesTheSameTableAndDropsNonNumericParts() {
        for (month, offset, expected) in Self.monthShiftRows {
            #expect(BudgetViewportModel.monthID(month, offsetBy: offset) == expected, "\(month) \(offset)")
        }
        #expect(BudgetViewportModel.monthID("a-2026-01", offsetBy: 1) == "2026-02")
    }

    // MARK: Bank sync

    @Test func bankSyncUnixSecondsMapToTheUTCCompactDay() {
        let rows: [(Int64, String)] = [
            (0, "19700101"), (-1, "19691231"), (951_782_400, "20000229"),
            (1_773_576_000, "20260315"), (1_798_761_599, "20261231"),
            (1_798_761_600, "20270101"), (253_402_257_600, "99991231"),
        ]
        for (seconds, expected) in rows {
            #expect(BankSyncAmounts.dayID(fromUnixSeconds: seconds) == expected, "\(seconds)")
        }
    }

    @Test func bankSyncLookbackStartInUTCHonoursTheOldestLiveDay() {
        let noon = Date(timeIntervalSince1970: 1_773_576_000)
        let justBeforeUTCMidnight = Date(timeIntervalSince1970: 1_773_532_799)
        #expect(BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: nil, now: noon, timeZone: .gmt) == "2025-12-16")
        #expect(BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: nil, now: justBeforeUTCMidnight, timeZone: .gmt) == "2025-12-15")
        #expect(BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: "20260101", now: noon, timeZone: .gmt) == "2026-01-01")
        #expect(BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: "20250101", now: noon, timeZone: .gmt) == "2025-12-16")
        #expect(BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: "2026-01-01", now: noon, timeZone: .gmt) == "2025-12-16")
    }

    @Test func bankSyncTodayInUTCIsTheUTCDay() {
        #expect(BankSyncAmounts.todayDayID(now: Date(timeIntervalSince1970: 1_773_532_799), timeZone: .gmt) == "20260314")
        #expect(BankSyncAmounts.todayDayID(now: Date(timeIntervalSince1970: 1_773_532_800), timeZone: .gmt) == "20260315")
        #expect(BankSyncAmounts.todayDayID(now: Date(timeIntervalSince1970: 1_798_761_599), timeZone: .gmt) == "20261231")
    }

    @Test func simpleFINBridgeQueryStartsAtUTCMidnightAndResponseDaysParseAtUTCNoon() {
        let flexible: [(String, Int64?)] = [
            ("2024-01-01", 1_704_110_400), ("2026-03-15", 1_773_576_000), ("1970-01-01", 43_200),
            ("0001-01-01", -62_135_726_400), ("9999-12-31", 253_402_257_600),
            ("2026-02-31", nil), ("2026-13-01", nil), ("", nil), ("2026-1-5", nil), ("0000-01-01", nil),
            ("-2026-1-05", nil), ("abcd-01-05", nil),
        ]
        for (input, expected) in flexible {
            #expect(FlexibleUnixSeconds.unixSeconds(fromDay: input) == expected, "\(input)")
        }
        let bridge: [(String, Int)] = [
            ("2024-01-01", 1_704_067_200), ("2026-03-15", 1_773_532_800),
            ("2026-02-31", 1_772_496_000), ("2026-13-01", 1_798_761_600),
            ("", 0), ("2026-1-5", 0),
            ("abcd-01-05", -62_135_424_000), ("-2026-1-05", -68_546_908_800),
        ]
        for (input, expected) in bridge {
            #expect(SimpleFINBridgeClient.unixSeconds(fromDay: input) == expected, "\(input)")
        }
    }

    // MARK: Device-zone parser

    @Test func actualDateParsesAtDeviceZoneNoonAndAcceptsShortFields() {
        let calendar = Calendar(identifier: .gregorian)
        let rows: [(String, [Int]?)] = [
            ("2026-03-15", [2026, 3, 15]),
            ("2026-02-31", [2026, 3, 3]),
            ("2026-1-5", [2026, 1, 5]),
            ("2026-01-05 ", [2026, 1, 5]),
            ("26-01-05", [26, 1, 5]),
            ("2026-13-01", nil),
            ("", nil),
            ("2026-01-05T10:00", nil),
            ("+2026-01-05", nil),
        ]
        for (input, expected) in rows {
            let date = input.actualDate
            let parts = date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
            #expect(parts.map { [$0.year!, $0.month!, $0.day!] } == expected, "\(input)")
        }
        #expect("2026-03-15".actualDate.map { calendar.component(.hour, from: $0) } == 12)
    }
}
