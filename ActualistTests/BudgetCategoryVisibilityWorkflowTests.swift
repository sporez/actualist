import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetCategoryVisibilityWorkflowTests {
    @Test func submittingCategoryHideRecordsTheCommand() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryVisibilityWorkflow()
        let loaded = try #require(
            await workflow.setCategoryHidden(
                true,
                categoryID: "mortgage",
                groupHidden: false,
                selectedMonth: "2026-06",
                budgetID: "budget",
                repository: repository
            )
        )

        #expect(loaded.selectedMonth == "2026-06")
        let recorded = try await repository.onlyCategoryHide()
        #expect(recorded.categoryID == "mortgage")
        #expect(recorded.hidden)
        #expect(recorded.month == "2026-06")
        #expect(workflow.errorMessage == nil)
        #expect(!workflow.isSubmitting)
    }

    @Test func cannotHideACategoryInAHiddenGroup() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryVisibilityWorkflow()
        let loaded = await workflow.setCategoryHidden(
            true,
            categoryID: "secret",
            groupHidden: true,
            selectedMonth: "2026-06",
            budgetID: "budget",
            repository: repository
        )

        #expect(loaded == nil)
        #expect(workflow.errorMessage == "Show the group before changing a category.")
        #expect(await repository.recordedCategoryHides().isEmpty)
    }

    @Test func cannotHideAnIncomeGroup() async {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryVisibilityWorkflow()
        let income = BudgetMonthCategoryGroup(
            id: "income",
            name: "Income",
            isIncome: true,
            hidden: false,
            budgeted: 0,
            spent: 0,
            balance: 0,
            categories: []
        )

        let loaded = await workflow.setGroupHidden(
            true,
            group: income,
            selectedMonth: "2026-06",
            budgetID: "budget",
            repository: repository
        )
        #expect(loaded == nil)
        #expect(workflow.errorMessage == "Income groups cannot be hidden.")
    }

    @Test func cancelDropsAStaleMonthResult() async throws {
        let repository = DelayedVisibilityRepository()
        let workflow = BudgetCategoryVisibilityWorkflow()
        let task = Task {
            await workflow.setCategoryHidden(
                true,
                categoryID: "mortgage",
                groupHidden: false,
                selectedMonth: "2026-06",
                budgetID: "budget",
                repository: repository
            )
        }
        await repository.waitUntilStarted()
        workflow.cancel()
        await repository.finish()
        let loaded = await task.value
        #expect(loaded == nil)
        #expect(!workflow.isSubmitting)
    }
}

private actor DelayedVisibilityRepository: BudgetRepositoryProtocol {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        if !didStart {
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        await didUpdate()
        return emptyLoadedMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }
}

private let emptyLoadedMonth = LoadedBudgetMonth(
    availableMonths: ["2026-06"],
    selectedMonth: "2026-06",
    month: try! JSONDecoder().decode(BudgetMonth.self, from: Data("""
    {
      "month": "2026-06",
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
    """.utf8)),
    alerts: []
)
