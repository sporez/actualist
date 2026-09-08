import AppIntents
import Foundation
import Testing
@testable import Actualist

@MainActor
struct TrackingBudgetConsumerTests {
    @Test(arguments: [BudgetCurrency.usd, .jpy, .none])
    func snapshotsAndShortcutsSharePlannedAndClosedSummary(currency: BudgetCurrency) throws {
        let month = try TrackingBudgetPresentationTests.month("2026-08")
        var loaded = TrackingBudgetPresentationTests.loaded(month)
        loaded.currency = currency
        for current in ["2026-08", "2026-09"] {
            let summary = BudgetSummaryEntity.make(from: loaded, currentMonth: current)
            let expected = try #require(month.trackingSummary?.headline(month: month.month, currentMonth: current))
            #expect(summary.id == month.month)
            #expect(summary.budgetType == "Tracking")
            #expect(summary.readyToAssign == nil)
            #expect(summary.fromLastMonth == nil)
            #expect(summary.forNextMonth == nil)
            #expect(summary.incomeAvailable == nil)
            #expect(summary.savings?.amount == currency.displayAmount(fromMinorUnits: expected.amount))
            #expect(summary.savingsLabel == expected.kind.title)
            #expect(summary.spokenSummary.contains(currency.formatted(expected.amount)))
            #expect(!summary.spokenSummary.lowercased().contains("assign"))
            let snapshot = makeSnapshot(month: month, currency: currency, now: date(current))
            #expect(snapshot.isTrackingBudget == true)
            #expect(snapshot.overview?.toBudget == nil)
            #expect(snapshot.overview?.displayedSummary?.amount.minorUnits == expected.amount)
            #expect(snapshot.overview?.displayedSummary?.kind.title == expected.kind.title)
            #expect(snapshot.overview?.balanceLabel == "Balance")
            let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
            #expect(restored == snapshot)
        }
    }

    @Test func legacyWidgetSnapshotAndCategoryBindingsSurviveAddedFields() throws {
        let json = #"{"schemaVersion":2,"budgetID":"fixture","budgetName":"Budget","month":"2026-08","privacyEnabled":false,"updatedAt":0,"categories":[],"overview":{"income":{"minorUnits":100,"formatted":"1"},"spent":{"minorUnits":50,"formatted":"0.50"},"toBudget":{"minorUnits":25,"formatted":"0.25"},"budgeted":{"minorUnits":25,"formatted":"0.25"},"available":{"minorUnits":0,"formatted":"0"}}}"#
        let old = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        #expect(old.overview?.displayedSummary?.kind == .toBudget)
        #expect(old.overview?.displayedSummary?.amount.minorUnits == 25)
        #expect(old.isTrackingBudget == nil)
        #expect(CategoryBalanceMetric(rawValue: "available") == .available)
        #expect(CategoryBalanceMetric(rawValue: "spent") == .spent)
        #expect(CategoryBalanceMetric(rawValue: "budgeted") == .budgeted)
    }

    @Test func incomeAndExpensePropertiesDoNotRepurposeEnvelopeFields() throws {
        let month = try TrackingBudgetPresentationTests.month()
        let salary = CategoryEntity.make(from: month.categoryGroups[0].categories[0], groupName: "Income", currency: .usd, isTrackingBudget: true)
        #expect(salary.id == "salary")
        #expect(salary.available == nil && salary.balance == nil && salary.spent == nil)
        #expect(salary.received?.amount == 4500)
        #expect(salary.budgeted?.amount == 5000)
        let food = CategoryEntity.make(from: month.categoryGroups[1].categories[0], groupName: "Expenses", currency: .usd, isTrackingBudget: true)
        #expect(food.available == nil && food.received == nil)
        #expect(food.balance?.amount == -100)
        #expect(food.spent?.amount == -700)
        let picker = month.editorCategoryGroups(currency: .usd)
        #expect(picker.first?.options.first?.id == salary.id)
        #expect(picker.first?.options.first?.amount == nil)
        #expect(!picker.contains { $0.name == "To Budget" })
    }

    @Test func sampleWidgetSummaryAndAttentionUseOnlySampleVisibleValues() throws {
        let month = try TrackingBudgetPresentationTests.month()
        let sample = BudgetMonthPrivacyProjection.project(month, currency: .usd)
        let snapshot = makeSnapshot(month: month, currency: .usd, now: date("2026-08"), privacy: true)
        #expect(snapshot.overview?.summary?.amount.minorUnits == sample.trackingSummary?.plannedSavings)
        #expect(snapshot.attention?.overspentCategoryIDs == snapshot.categories.filter { !$0.isHidden && $0.availableMinorUnits < 0 }.map(\.id))
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("Private"))
        #expect(snapshot.overview?.summary?.amount.minorUnits != month.trackingSummary?.plannedSavings)
    }

    private func makeSnapshot(month: BudgetMonth, currency: BudgetCurrency, now: Date, privacy: Bool = false) -> WidgetSnapshot {
        WidgetFinancialSnapshotBuilder.make(source: WidgetBudgetSource(month: month, currency: currency, accounts: nil,
            attention: .init(uncategorizedCount: 0, overspentCategoryIDs: ["food"]), recentTransactions: nil,
            transactionLookup: .init(), netWorth: nil), budgetID: "fixture", budgetName: "Private Budget", privacyEnabled: privacy, now: now)
    }

    private func date(_ month: String) -> Date {
        ReportCalendar.date(fromMonthID: month, calendar: ReportCalendar.gregorianLocal)!
    }
}

extension ShortcutIntentTests {
    @Test func savedTrackingReadAndWriteIntentsKeepIDsAndRejectEnvelopeMetrics() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: TrackingBudgetLifecycleTests.sql)
        let session = ShortcutsBudgetSession(appState: try fixtures.makeAppState(for: bundle))
        let salary = try await session.category(id: "salary", month: "2026-07")
        #expect(try await session.categories(includeHidden: false, month: "2026-07").contains { $0.id == "salary" })
        let summary = GetBudgetSummaryIntent()
        summary.session = session
        summary.month = .make(monthID: "2026-07")
        #expect(try await summary.perform().value?.budgetType == "Tracking")
        let ready = GetReadyToAssignIntent()
        ready.session = session
        ready.month = .make(monthID: "2026-07")
        await #expect(throws: ShortcutsError.trackingActionUnsupported) { _ = try await ready.perform() }
        let metric = GetCategoryBalanceIntent()
        metric.session = session
        metric.category = salary
        metric.month = .make(monthID: "2026-07")
        metric.metric = .available
        await #expect(throws: ShortcutsError.metricUnavailable) { _ = try await metric.perform() }
        metric.metric = .received
        #expect(try await metric.perform().value?.amount == salary.received?.amount)
        let saved = try await ShortcutBudgetCommand.assign(categoryID: "salary", amountMinorUnits: 5000, month: "2026-07", session: session)
        #expect(saved.id == salary.id)
        #expect(saved.budgeted?.amount == 50)
        await #expect(throws: ShortcutsError.trackingActionUnsupported) {
            _ = try await ShortcutBudgetCommand.move(fromCategoryID: "groceries", toCategoryID: "utilities", amountMinorUnits: 1, month: "2026-07", session: session)
        }
    }
}
