import Foundation
import Testing
@testable import Actualist

/// Actual's `monthUtils.currentDay()` is the local date, so the days Bank Sync
/// derives from "now" follow the device zone, not UTC (Decision Register D8).
/// The oracle pins Actual's day to 2017-01-01 and cannot see this.
struct BankSyncLocalDayTests {
    /// 2026-03-15 23:30 UTC: already the 16th east of UTC+0:30.
    private static let lateUTC = Date(timeIntervalSince1970: 1_773_617_400)
    /// 2026-03-15 05:00 UTC: still the 14th west of UTC-5.
    private static let earlyUTC = Date(timeIntervalSince1970: 1_773_550_800)
    private static let east = TimeZone(identifier: "Pacific/Kiritimati")!
    private static let west = TimeZone(identifier: "Pacific/Pago_Pago")!

    @Test func todayIsTheDayInTheGivenZone() {
        #expect(BankSyncAmounts.todayDayID(now: Self.lateUTC, timeZone: .gmt) == "20260315")
        #expect(BankSyncAmounts.todayDayID(now: Self.lateUTC, timeZone: Self.east) == "20260316")
        #expect(BankSyncAmounts.todayDayID(now: Self.earlyUTC, timeZone: .gmt) == "20260315")
        #expect(BankSyncAmounts.todayDayID(now: Self.earlyUTC, timeZone: Self.west) == "20260314")
    }

    @Test func lookbackStartIs89DaysBeforeTheLocalDay() {
        func start(_ now: Date, _ zone: TimeZone, oldest: String? = nil) -> String {
            BankSyncAmounts.lookbackStartDate(oldestLiveTransactionDayID: oldest, now: now, timeZone: zone)
        }
        #expect(start(Self.lateUTC, .gmt) == "2025-12-16")
        #expect(start(Self.lateUTC, Self.east) == "2025-12-17")
        #expect(start(Self.earlyUTC, .gmt) == "2025-12-16")
        #expect(start(Self.earlyUTC, Self.west) == "2025-12-15")
        // A newer oldest live day still wins.
        #expect(start(Self.lateUTC, Self.east, oldest: "20260101") == "2026-01-01")
    }

    @Test func openingBalanceWithoutCandidatesIsDatedOnTheLocalDay() {
        func dayID(_ now: Date, _ zone: TimeZone) -> String? {
            BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: 4_200,
                inserts: [],
                earliestDayID: nil,
                accountHadLiveTransactions: false,
                now: now,
                timeZone: zone
            )?.dayID
        }
        #expect(dayID(Self.lateUTC, .gmt) == "20260315")
        #expect(dayID(Self.lateUTC, Self.east) == "20260316")
        #expect(dayID(Self.earlyUTC, Self.west) == "20260314")
    }

    @Test func ruleFormulaTodayIsTheLocalDay() {
        func today(_ now: Date, _ zone: TimeZone) -> String {
            RuleSplitActionExecutor.formulaContext(from: Self.ruleContext(), now: now, timeZone: zone).today
        }
        #expect(today(Self.lateUTC, .gmt) == "2026-03-15")
        #expect(today(Self.lateUTC, Self.east) == "2026-03-16")
        #expect(today(Self.earlyUTC, Self.west) == "2026-03-14")
    }

    private static func ruleContext() -> RuleEvaluationContext {
        RuleEvaluationContext(
            accountID: "checking",
            accountName: "Checking",
            accountIsOffBudget: false,
            amount: -500,
            categoryID: nil,
            categoryName: nil,
            categoryGroupID: nil,
            categoryGroupName: nil,
            date: Date(timeIntervalSince1970: 0),
            dateTimeZone: ActualDateOnly.utc,
            notes: nil,
            payeeID: nil,
            payeeName: "",
            importedPayee: nil,
            cleared: false,
            reconciled: false,
            isTransfer: false,
            isParent: false,
            accountNames: [:],
            offBudgetAccountIDs: [],
            categoryNames: [:],
            categoryGroupsByCategoryID: [:],
            categoryGroupNames: [:],
            payeeNames: [:]
        )
    }
}
