import Foundation
import Testing
@testable import Actualist

@Suite("Budget template apply preview view model")
@MainActor
struct BudgetTemplateApplyPreviewViewModelTests {
    @Test(arguments: CancellationTestCase.allCases)
    func cancelledPreviewCannotEnableApply(_ kind: CancellationTestCase) async {
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.load(confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
                         budgetID: "budget", randomized: false,
                         repository: ApplyPreviewRepository(error: kind.error))
        #expect(model.phase == .idle)
        #expect(model.errorMessage == nil)
        #expect(!model.canApply)
    }

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

    @Test func convertedPreviewFailsInsteadOfRemainingLoading() async {
        let reviewed = BudgetModeIdentity(storageID: "fixture", table: .envelope, revision: "before")
        let converted = BudgetModeIdentity(storageID: "fixture", table: .tracking, revision: "after")
        var preview = BudgetTemplateApplyPreview.empty
        preview.modeIdentity = converted
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
            budgetID: "budget-1", modeIdentity: reviewed, randomized: false,
            repository: ApplyPreviewRepository(preview: preview)
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(viewModel.errorMessage == BudgetModeWriteError.budgetChanged.localizedDescription)
    }

    @Test func readyPreviewKeepsItsReviewedIdentity() async {
        let reviewed = BudgetModeIdentity(storageID: "fixture", table: .tracking, revision: "review")
        var preview = BudgetTemplateApplyPreview.empty
        preview.modeIdentity = reviewed
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
            budgetID: "budget-1", modeIdentity: reviewed, randomized: false,
            repository: ApplyPreviewRepository(preview: preview)
        )
        #expect(viewModel.canApply)
        #expect(viewModel.modeIdentity == reviewed)
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

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
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
