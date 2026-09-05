import Testing
@testable import Actualist

@MainActor
struct BudgetViewportModelTests {
    @Test func monthArithmeticCrossesYearBoundaries() {
        #expect(BudgetViewportModel.monthID("2026-12", offsetBy: 1) == "2027-01")
        #expect(BudgetViewportModel.monthID("2027-01", offsetBy: -1) == "2026-12")
    }

    @Test func viewportCountIsClampedAndVisibleMonthsStayAnchored() {
        let model = BudgetViewportModel(repository: ViewportTestRepository())
        model.setResolvedMonthCount(9)
        #expect(model.resolvedMonthCount == 5)
        #expect(model.visibleMonths.isEmpty)
    }

    @Test func hardwareInputUsesCurrencyMinorUnitScale() {
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12.34", currency: .usd) == "1234")
        #expect(BudgetAssignmentHardwareInput.minorDigits(for: "12", currency: .jpy) == "12")
        #expect(BudgetAssignmentHardwareInput.action(for: "\t") == .next)
        #expect(BudgetAssignmentHardwareInput.action(for: "\u{19}") == .previous)
        #expect(BudgetAssignmentHardwareInput.action(for: "1x") == nil)
    }
    @Test func firstVisibleMonthAssignmentRefreshesLaterVisibleSQLiteMonth() async throws {
        let support = LocalFirstActualStoreTests()
        let bundle = try await support.makeOpenedWritableStoreBundle(
            additionalFixtureSQL: "INSERT INTO zero_budgets VALUES (202608, 'groceries', 0, 1);"
        )
        let model = BudgetViewportModel(repository: bundle.store)
        model.setResolvedMonthCount(2)
        await model.load(budgetID: "group-1", anchorMonth: "2026-07")
        let beforeAugust = try #require(model.snapshot(for: "2026-08"))
        #expect(model.snapshot(for: "2026-08") != nil)
        model.beginAssignmentEditing(categoryID: "groceries", month: "2026-07")
        for digit in [1, 0, 0, 0, 0] { model.assignmentWorkflow.appendDigit(digit) }
        #expect(await model.submitAssignment())
        #expect(model.snapshot(for: "2026-07")?.month.categoryGroups
            .flatMap(\.categories).first { $0.id == "groceries" }?.budgeted == 10_000)
        let afterAugust = try #require(model.snapshot(for: "2026-08"))
        let storedAugust = try await bundle.store.fetchBudgetMonthUncached(
            budgetID: "group-1", month: "2026-08"
        ).month
        #expect(afterAugust.month == storedAugust)
        #expect(beforeAugust.month != afterAugust.month)
    }
}

private struct ViewportTestRepository: BudgetRepositoryProtocol {
    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth {
        throw BudgetViewportTestError.unimplemented
    }

    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth {
        throw BudgetViewportTestError.unimplemented
    }

    func assignCategoryBudgetAndRefresh(categoryID: String, budgeted: Int, budgetID: String, month: String, didAssign: @escaping () async -> Void) async throws -> LoadedBudgetMonth {
        throw BudgetViewportTestError.unimplemented
    }

    func setCategoryCarryoverAndRefresh(categoryID: String, carryover: Bool, budgetID: String, startMonth: String, didSetCarryover: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func setAllExpenseCategoryCarryoverAndRefresh(carryover: Bool, budgetID: String, startMonth: String) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func setCategoryHiddenAndRefresh(categoryID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func setCategoryGroupHiddenAndRefresh(groupID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func applyBudgetTemplateAndRefresh(command: BudgetTemplateCommand, budgetID: String, month: String, didApply: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func moveMoneyAndRefresh(command: BudgetMoveMoneyCommand, budgetID: String, month: String, didMove: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func moveMoneyAndRefresh(commands: [BudgetMoveMoneyCommand], budgetID: String, month: String, didMove: @escaping () async -> Void) async throws -> LoadedBudgetMonth { throw BudgetViewportTestError.unimplemented }
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview { throw BudgetViewportTestError.unimplemented }
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws { throw BudgetViewportTestError.unimplemented }
}

private enum BudgetViewportTestError: Error { case unimplemented }
