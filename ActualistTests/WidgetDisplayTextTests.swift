import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import Actualist

struct WidgetDisplayTextTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private var noon: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    }

    private func transaction(date: String) -> WidgetTransactionSnapshot {
        WidgetTransactionSnapshot(id: "id", accountID: "account", accountName: "Checking", payee: "Market", date: date, amount: nil)
    }

    private func money(_ minorUnits: Int) -> WidgetMoney {
        WidgetMoney(minorUnits: minorUnits, formatted: String(minorUnits))
    }

    private func netWorth(change: Int, points: [Int]) -> WidgetNetWorthSnapshot {
        WidgetNetWorthSnapshot(
            balance: money(points.last ?? 0), change: money(change), period: "6 months",
            points: points.enumerated().map { index, amount in
                WidgetNetWorthPoint(date: Date(timeIntervalSince1970: Double(index) * 86_400), amount: money(amount))
            }
        )
    }

    @Test(arguments: [
        ("2026-10-15", "Today"),
        ("2026-10-14", "Yesterday"),
        ("2026-10-13", "Oct 13"),
        ("2026-10-16", "Oct 16")
    ])
    func namesRecentDays(date: String, expected: String) {
        #expect(transaction(date: date).dayText(now: noon, calendar: calendar) == expected)
    }

    @Test func crossesMonthBoundariesForYesterday() {
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 8))!
        #expect(transaction(date: "2026-09-30").dayText(now: first, calendar: calendar) == "Yesterday")
    }

    @Test(arguments: ["Sep 20", "", "2026-10"])
    func keepsStoredTextThatIsNotADate(date: String) {
        #expect(transaction(date: date).dayText(now: noon, calendar: calendar) == date)
    }

    @Test func attentionStatusFollowsTheWorstIssue() {
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 0, overspentCategoryIDs: []).status == .positive)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 3, overspentCategoryIDs: []).status == .caution)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 0, overspentCategoryIDs: ["a"]).status == .negative)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 3, overspentCategoryIDs: ["a"]).status == .negative)
    }

    @Test func wholeWidgetTapGoesToTheOnlyIssue() {
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 3, overspentCategoryIDs: []).primaryAction == .uncategorized)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 3, overspentCategoryIDs: ["a"]).primaryAction == .budget)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 0, overspentCategoryIDs: ["a"]).primaryAction == .budget)
        #expect(WidgetAttentionSnapshot(uncategorizedCount: 0, overspentCategoryIDs: []).primaryAction == .budget)
    }

    @Test func signsNetWorthGains() {
        #expect(netWorth(change: 500, points: []).changeText == "+500")
        #expect(netWorth(change: -500, points: []).changeText == "-500")
        #expect(netWorth(change: 0, points: []).changeText == "0")
    }

    @Test func chartDomainLeavesRoomAroundTheLine() {
        let domain = netWorth(change: 0, points: [1_000, 4_000, 2_000]).chartDomain
        #expect(domain.lowerBound < 1_000)
        #expect(domain.upperBound > 4_000)
    }

    @Test(arguments: [[5_000, 5_000], [5_000], []])
    func chartDomainStaysValidForFlatHistory(points: [Int]) {
        let domain = netWorth(change: 0, points: points).chartDomain
        #expect(domain.lowerBound < domain.upperBound)
    }

    @Test(arguments: ActualistThemeOption.allCases)
    func platesUseTheThemeStatusColors(theme: ActualistThemeOption) {
        let widget = WidgetPalette(theme: theme, renderingMode: .fullColor)
        let app = theme.palette
        #expect(widget.plateFill(.positive) == app.positive)
        #expect(widget.plateFill(.caution) == app.warning)
        #expect(widget.plateFill(.negative) == app.danger)
        #expect(widget.plateFill(.neutral) == app.neutral)
        #expect(widget.plateForeground(.caution) == app.warningForeground)
    }

    @Test func platesDropTheirFillWhenTheSystemTintsTheWidget() {
        let widget = WidgetPalette(theme: .actualPurple, renderingMode: .accented)
        #expect(widget.plateFill(.positive) == nil)
        #expect(widget.plateForeground(.negative) == .primary)
    }

    @Test func statusFollowsAmountTone() {
        #expect(WidgetStatus(.positive) == .positive)
        #expect(WidgetStatus(.zero) == .neutral)
        #expect(WidgetStatus(.negative) == .negative)
    }
}
