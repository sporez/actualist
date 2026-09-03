import Foundation
import Testing
@testable import Actualist

struct WidgetCategoryBalanceProjectionTests {
    @Test func familyCapacitiesMatchTheSupportedWidgetLayouts() {
        #expect(WidgetCategoryBalanceProjection.visibleCount(for: .medium) == 3)
        #expect(WidgetCategoryBalanceProjection.visibleCount(for: .large) == 8)
    }

    @Test func preservesConfigurationOrderAndAppliesFamilyLimit() {
        let (now, calendar) = july2026()
        let rows = WidgetCategoryBalanceProjection.rows(
            selectedIDs: ["fuel", "groceries"],
            snapshot: makeSnapshot(),
            now: now,
            calendar: calendar,
            limit: 1
        )

        #expect(rows.map(\.id) == ["fuel"])
        #expect(rows.first?.tone == .negative)
    }

    @Test func staleMonthRequiresTheAppInsteadOfShowingOldBalances() {
        let (now, calendar) = july2026()
        var snapshot = makeSnapshot()
        snapshot.month = "2026-06"
        let rows = WidgetCategoryBalanceProjection.rows(
            selectedIDs: ["groceries"],
            snapshot: snapshot,
            now: now,
            calendar: calendar,
            limit: 3
        )

        #expect(rows.isEmpty)
        #expect(
            WidgetCategoryBalanceState.resolve(
                selectedIDs: ["groceries"],
                snapshot: snapshot,
                rows: rows,
                now: now,
                calendar: calendar
            ) == .needsApp
        )
    }

    @Test func resolvesConfigurationAndMissingCategoryStates() {
        let (now, calendar) = july2026()
        let snapshot = makeSnapshot()

        #expect(
            WidgetCategoryBalanceState.resolve(
                selectedIDs: [],
                snapshot: snapshot,
                rows: [],
                now: now,
                calendar: calendar
            ) == .needsCategories
        )
        #expect(
            WidgetCategoryBalanceState.resolve(
                selectedIDs: ["deleted"],
                snapshot: snapshot,
                rows: [],
                now: now,
                calendar: calendar
            ) == .categoriesUnavailable
        )
    }

    private func july2026() -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        return (date, calendar)
    }

    private func makeSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            schemaVersion: WidgetSnapshot.currentSchemaVersion,
            budgetID: "budget",
            budgetName: "Household",
            month: "2026-07",
            privacyEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            categories: [
                WidgetCategorySnapshot(
                    id: "groceries",
                    displayName: "Groceries",
                    group: "Everyday",
                    isHidden: false,
                    availableMinorUnits: 12_345,
                    formattedAvailable: "$123.45"
                ),
                WidgetCategorySnapshot(
                    id: "fuel",
                    displayName: "Fuel",
                    group: "Everyday",
                    isHidden: false,
                    availableMinorUnits: -500,
                    formattedAvailable: "-$5.00"
                )
            ]
        )
    }
}
