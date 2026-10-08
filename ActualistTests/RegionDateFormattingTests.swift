import Foundation
import Testing
@testable import Actualist

/// User-visible days follow the device region, never ISO `yyyy-MM-dd`.
struct RegionDateFormattingTests {
    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")
    private let persian = Locale(identifier: "en_US@calendar=persian")

    @Test func ruleDateValuesFollowRegionAndKeepUnparseableText() {
        func text(_ value: RuleJSONValue, _ locale: Locale) -> String {
            RulePresentation.valueText(value, field: "date", options: nil, locale: locale)
        }
        #expect(text(.string("2026-10-09"), us) == "Oct 9, 2026")
        #expect(text(.string("2026-10-09"), gb) == "9 Oct 2026")
        #expect(text(.string("2026-10-09"), persian) == "Oct 9, 2026")
        #expect(text(.string("2026-10"), us) == "Oct 2026")
        #expect(text(.string("soon"), us) == "soon")
        let recurring = RuleJSONValue.object([
            "frequency": .string("monthly"),
            "start": .string("2026-10-09"),
        ])
        #expect(text(recurring, us) == "Monthly recurrence beginning Oct 9, 2026")
    }

    @Test func reportTitlesFollowRegion() {
        #expect(ReportCalendar.longDayTitle("2026-10-09", locale: us) == "Friday, October 9, 2026")
        #expect(ReportCalendar.longDayTitle("2026-10-09", locale: gb) == "Friday, 9 October 2026")
        #expect(ReportCalendar.longDayTitle("bad", locale: us) == "bad")
        #expect(ReportCalendar.dayRangeTitle(startDay: "2026-10-01", endDay: "2026-10-09", locale: us)
            == "Oct 1, 2026 – Oct 9, 2026")
        #expect(ReportCalendar.dayRangeTitle(startDay: "2026-10-01", endDay: "2026-10-09", locale: gb)
            == "1 Oct 2026 – 9 Oct 2026")
        #expect(ReportCalendar.rangeTitle(startDay: "2026-01-01", endDay: "2026-10-31", locale: us)
            == "Jan 2026 – Oct 2026")
        #expect(ReportCalendar.monthTitle("2026-10", locale: us) == "October 2026")
        #expect(ReportCalendar.shortMonthTitle("2026-10", locale: gb) == "Oct 2026")
    }

    @Test func importAndFilterReviewDatesFollowRegionAndKeepRawOnFailure() {
        #expect(TransactionCommandReviewFormatting.dateText("2026-10-09", locale: us) == "Oct 9, 2026")
        #expect(TransactionCommandReviewFormatting.dateText("2026-10-09", locale: gb) == "9 Oct 2026")
        #expect(TransactionCommandReviewFormatting.dateText("2026-02-31", locale: us) == "2026-02-31")
        #expect(!BankSyncCopy.dayText("20261009").contains("-"))
        #expect(BankSyncCopy.dayText("garbage") == "garbage")
    }
}
