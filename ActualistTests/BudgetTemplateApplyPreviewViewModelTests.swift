import Foundation
import Testing
@testable import Actualist

@Suite("Budget template apply preview view model")
@MainActor
struct BudgetTemplateApplyPreviewViewModelTests {
    @Test func readyPreviewCanApply() async {
        let repository = ApplyPreviewRepository(
            preview: BudgetTemplateApplyPreview(
                assigned: 40_000,
                leftover: 0,
                isTrackingBudget: false,
                currency: .usd,
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "groceries",
                        name: "Groceries",
                        current: 0,
                        proposed: 40_000,
                        perTemplate: [40_000],
                        drafts: []
                    )
                ]
            )
        )
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )
        #expect(viewModel.phase == .ready)
        #expect(viewModel.canApply)
        #expect(viewModel.display?.changeCountText == "1 category")
        #expect(viewModel.errorMessage == nil)
    }

    @Test func failedPreviewCannotApply() async {
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthFillEmpty,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: ApplyPreviewRepository(error: LocalFirstError.unsupportedTemplate("stale notes"))
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(viewModel.display == nil)
        #expect(viewModel.errorMessage != nil)
    }

    @Test func missingCategoryCannotApply() async {
        let repository = ApplyPreviewRepository(preview: .empty)
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .category,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(await repository.previewCallCount() == 0)
    }
}

private extension BudgetTemplateApplyPreview {
    static let empty = BudgetTemplateApplyPreview(
        assigned: 0,
        leftover: 0,
        isTrackingBudget: false,
        currency: .usd,
        categories: []
    )
}

private actor ApplyPreviewRepository: BudgetRepositoryProtocol {
    var preview: BudgetTemplateApplyPreview
    var error: Error?
    private var calls = 0

    init(preview: BudgetTemplateApplyPreview = .empty, error: Error? = nil) {
        self.preview = preview
        self.error = error
    }

    func previewCallCount() -> Int { calls }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        calls += 1
        if let error {
            throw error
        }
        return preview
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(
        actionID: String,
        budgetID: String
    ) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    private static let dummyMonth = LoadedBudgetMonth(
        availableMonths: ["2026-07"],
        selectedMonth: "2026-07",
        month: try! JSONDecoder().decode(BudgetMonth.self, from: Data(#"""
            {
              "month": "2026-07",
              "incomeAvailable": 0,
              "lastMonthOverspent": 0,
              "forNextMonth": 0,
              "totalBudgeted": 0,
              "toBudget": 0,
              "fromLastMonth": 0,
              "totalIncome": 0,
              "totalSpent": 0,
              "totalBalance": 0,
              "categoryGroups": []
            }
            """#.utf8)),
        alerts: []
    )
}
