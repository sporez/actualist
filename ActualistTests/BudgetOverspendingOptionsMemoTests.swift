import Foundation
import Testing
@testable import Actualist

/// Phase 5.6: the overspent options are read many times per render; the view
/// model builds one list per distinct month and settings.
/// `BudgetOverspendingPresentation.options` is the oracle.
@MainActor
struct BudgetOverspendingOptionsMemoTests {
    private func month(visible: Int, hidden: Int, carryover: Bool = false) throws -> BudgetMonth {
        try BudgetViewModelFixtures.decodeBudgetMonth(
            visibleCategoryBalance: visible, hiddenCategoryBalance: hidden,
            visibleCategoryCarryover: carryover, lastMonthOverspent: 0)
    }

    @Test func memoizedOptionsMatchThePresentationAndBuildOncePerDistinctInputs() throws {
        let model = BudgetViewModel()
        model.budgetMonth = try month(visible: -2_500, hidden: -5_000, carryover: true)

        func oracle() -> [BudgetOverspentCategoryOption] {
            BudgetOverspendingPresentation.options(
                in: model.budgetMonth, isTrackingBudget: model.isTrackingBudget,
                includeCarryover: model.includeCarryoverCategoriesInOverspentAlerts)
        }
        for _ in 0..<12 { #expect(model.overspentCategoryOptions.map(\.id) == oracle().map(\.id)) }
        #expect(model.overspentOptionsBuildCount == 1)

        model.includeCarryoverCategoriesInOverspentAlerts = true
        #expect(model.overspentCategoryOptions.map(\.id) == oracle().map(\.id))
        #expect(model.overspentCategoryOptions.count > 1)
        #expect(model.overspentOptionsBuildCount == 2)

        model.budgetMonth = try month(visible: -100, hidden: 0)
        #expect(model.overspentCategoryOptions.map(\.id) == oracle().map(\.id))
        #expect(model.overspentOptionsBuildCount == 3)

        model.budgetMonth = nil
        #expect(model.overspentCategoryOptions.isEmpty)
        #expect(model.overspentOptionsBuildCount == 4)
    }
}
