import Foundation
import Testing
@testable import Actualist

@MainActor
struct ActualDateDisplayTests {
    private static let nonGregorianLocales = [
        "en_US@calendar=persian", "en_US@calendar=buddhist",
        "en_US@calendar=islamic", "en_US@calendar=hebrew",
    ].map(Locale.init(identifier:))

    private static let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    @Test func monthAndDayTextStayGregorianOnEveryDeviceCalendar() {
        for locale in Self.nonGregorianLocales {
            #expect(ActualDateDisplay.monthYear("2026-09", locale: locale) == "Sep 2026", "\(locale.identifier)")
            #expect(ActualDateDisplay.monthYear("2026-09", width: .wide, locale: locale) == "September 2026")
            #expect(ActualDateDisplay.longDay("2026-09-01", locale: locale) == "September 1, 2026")
            #expect(TransactionGrouping.displayTitle("2026-09-01", locale: locale) == "September 1, 2026")
            #expect(BudgetMonthNavigationPresentation.title(for: "2026-09", locale: locale) == "Sep 2026")
        }
        #expect(ActualDateDisplay.weekdayLongDay("2026-03-05", locale: Locale(identifier: "en_US"))
            == "Thursday, March 5, 2026")
    }

    @Test func mediumDayAndMonthNameStayGregorianOnEveryDeviceCalendar() {
        for locale in Self.nonGregorianLocales {
            #expect(ActualDateDisplay.mediumDay("2026-09-01", locale: locale) == "Sep 1, 2026", "\(locale.identifier)")
            #expect(ActualDateDisplay.monthName("2026-09", locale: locale) == "September", "\(locale.identifier)")
            #expect(TransactionCommandReviewFormatting.dateText("2026-09-01", locale: locale) == "Sep 1, 2026")
        }
        #expect(ActualDateDisplay.mediumDay("2026-13-01") == nil)
        #expect(ActualDateDisplay.monthName("2026-13") == nil)
        #expect(TransactionCommandReviewFormatting.dateText("", locale: Locale(identifier: "en_US")) == "Date unavailable")
    }

    @Test func todayIsTheDayInTheInjectedZoneNotTheUTCDay() {
        // 2026-01-01T00:00Z is already Jan 1 at +14 and still Dec 31 at -8.
        let instant = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let east = TimeZone(secondsFromGMT: 14 * 3_600)!
        let west = TimeZone(secondsFromGMT: -8 * 3_600)!
        #expect(ActualDateOnly.today(now: instant, timeZone: east) == "2026-01-01")
        #expect(ActualDateOnly.today(now: instant, timeZone: west) == "2025-12-31")
        #expect(ActualDateOnly.today(now: instant.addingTimeInterval(12 * 3_600), timeZone: east) == "2026-01-02")
    }

    @Test func monthIDFormattingPadsAndKeepsOutOfRangeValues() {
        #expect(YearMonth.id(year: 2026, month: 3) == "2026-03")
        #expect(YearMonth.id(packed: 202_612) == "2026-12")
        #expect(YearMonth.id(year: 12, month: 0) == "0012-00")
        #expect(YearMonth(year: 1899, month: 1) == nil)
    }

    @Test func malformedIdsFallBackToTheRawValue() {
        #expect(ActualDateDisplay.monthYear("2026-13") == nil)
        #expect(TransactionGrouping.displayTitle("not-a-day") == "not-a-day")
        #expect(BudgetMonthNavigationPresentation.title(for: "garbage") == "garbage")
    }

    @Test func currentMonthTitleUsesTheInjectedTimeZone() {
        // 2026-09-30 23:30 UTC is already October in Auckland.
        let instant = ActualDateOnly.date(from: "2026-09-30", timeZone: .gmt)!.addingTimeInterval(11.5 * 3_600)
        let locale = Locale(identifier: "en_US")
        #expect(BudgetMonthNavigationPresentation.title(
            for: nil, now: instant, timeZone: Self.auckland, locale: locale) == "Oct 2026")
        #expect(BudgetMonthNavigationPresentation.title(
            for: nil, now: instant, timeZone: .gmt, locale: locale) == "Sep 2026")
    }

    @Test func shortcutsTransactionTitleShowsTheStoredDayEastOfUTC() {
        let aucklandNoon = ActualDateOnly.date(from: "2026-03-05", timeZone: Self.auckland)!
        let entity = TransactionEntity(
            id: "t1", amount: nil, date: aucklandNoon, dayID: "2026-03-05", payee: "Shop",
            account: "Checking", category: nil, notes: nil, cleared: false, isTransfer: false
        )

        let title = String(localized: entity.displayRepresentation.title)
        #expect(title.contains("March 5, 2026"), "\(title)")
    }

    @Test func actionLogUsesTheWritersTimeZoneForTheDraftDay() {
        let eveningInLosAngeles = ActualDateOnly.date(from: "2026-03-05", timeZone: Self.losAngeles)!
            .addingTimeInterval(8 * 3_600)
        let existing = ActualTransaction(
            id: "t1", account: "checking", date: "2026-03-05", amount: -1_200, payee: "market",
            payeeName: nil, importedPayee: nil, category: "food", notes: nil, cleared: .bool(false)
        )
        let draft = TransactionDraft(
            accountID: "checking", date: eveningInLosAngeles, amountMinorUnits: -1_200,
            payeeID: "market", payeeName: "Market", categoryID: "food", notes: nil,
            cleared: false, isTransfer: false
        )

        #expect(!BudgetTransactionLogging.shouldRecordUpdate(
            existing: existing, draft: draft, resolvedPayeeID: "market", timeZone: Self.losAngeles))
        #expect(BudgetTransactionLogging.shouldRecordUpdate(
            existing: existing, draft: draft, resolvedPayeeID: "market", timeZone: .gmt))
    }
}
