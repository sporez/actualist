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
