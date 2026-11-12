import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetCategoryFlagWorkflowTests {
    @Test func submittingCategoryHideRecordsTheCommand() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let loaded = try #require(
            await workflow.setCategoryHidden(
                true,
                categoryID: "mortgage",
                groupHidden: false,
                selectedMonth: "2026-06",
                budgetID: "budget",
                currentBudgetID: { "budget" },
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

    @Test func rolloverTogglesFromTheSelectedMonthWithTheExpectedBudgetType() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let mode = BudgetModeIdentity(storageID: "db-1", table: .tracking, revision: "r1")
        let loaded = await workflow.setCategoryCarryover(
            true,
            category: rolloverCategory(isIncome: false),
            expectedMode: mode,
            selectedMonth: "2026-06",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )

        #expect(loaded != nil)
        let recorded = try await repository.onlyCarryoverUpdate()
        #expect(recorded.categoryID == "groceries")
        #expect(recorded.carryover)
        #expect(recorded.expectedMode == mode)
        #expect(recorded.budgetID == "budget")
        #expect(recorded.startMonth == "2026-06")
        #expect(workflow.errorMessage == nil)
        #expect(!workflow.isSubmitting)
    }

    @Test func rolloverIsRefusedForIncomeCategories() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let loaded = await workflow.setCategoryCarryover(
            true,
            category: rolloverCategory(isIncome: true),
            expectedMode: nil,
            selectedMonth: "2026-06",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )

        #expect(loaded == nil)
        #expect(workflow.errorMessage == "Rollover is only available for expense categories.")
        #expect(await repository.carryoverUpdateCount() == 0)
    }

    @Test func aFailedRolloverWriteReportsTheError() async {
        let repository = RecordingBudgetRepository(carryoverError: BudgetModeWriteError.budgetChanged)
        let workflow = BudgetCategoryFlagWorkflow()
        let loaded = await workflow.setCategoryCarryover(
            false,
            category: rolloverCategory(isIncome: false),
            expectedMode: nil,
            selectedMonth: "2026-06",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )

        #expect(loaded == nil)
        #expect(workflow.errorMessage == BudgetModeWriteError.budgetChanged.userFacingMessage)
        #expect(!workflow.isSubmitting)
    }

    @Test func aSecondWriteIsRefusedWhileRolloverIsSubmitting() async throws {
        let repository = RecordingBudgetRepository(suspendsCarryover: true)
        let workflow = BudgetCategoryFlagWorkflow()
        let first = Task {
            await workflow.setCategoryCarryover(
                true,
                category: rolloverCategory(isIncome: false),
                expectedMode: nil,
                selectedMonth: "2026-06",
                budgetID: "budget",
                currentBudgetID: { "budget" },
                repository: repository
            )
        }
        await repository.waitUntilCarryoverStarted()
        try #require(workflow.isSubmitting)

        let second = await workflow.setCategoryHidden(
            true,
            categoryID: "groceries",
            groupHidden: false,
            selectedMonth: "2026-06",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )
        #expect(second == nil)
        #expect(await repository.recordedCategoryHides().isEmpty)

        await repository.resumeCarryover()
        #expect(await first.value != nil)
        #expect(!workflow.isSubmitting)
        #expect(await repository.carryoverUpdateCount() == 1)
    }

    @Test func cannotHideACategoryInAHiddenGroup() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let loaded = await workflow.setCategoryHidden(
            true,
            categoryID: "secret",
            groupHidden: true,
            selectedMonth: "2026-06",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )

        #expect(loaded == nil)
        #expect(workflow.errorMessage == "Show the group first to change this category.")
        #expect(await repository.recordedCategoryHides().isEmpty)
    }

    @Test func cannotHideAnIncomeGroup() async {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
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
            currentBudgetID: { "budget" },
            repository: repository
        )
        #expect(loaded == nil)
        #expect(workflow.errorMessage == "Income groups cannot be hidden.")
    }

    @Test func aMonthChangeDuringTheWriteStillPublishesTheCommittedResult() async throws {
        let repository = DelayedVisibilityRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let task = Task {
            await workflow.setCategoryHidden(
                true,
                categoryID: "mortgage",
                groupHidden: false,
                selectedMonth: "2026-06",
                budgetID: "budget",
                currentBudgetID: { "budget" },
                repository: repository
            )
        }
        await repository.waitUntilStarted()
        workflow.cancel()
        try #require(workflow.isSubmitting)
        let second = await workflow.setCategoryHidden(
            false,
            categoryID: "mortgage",
            groupHidden: false,
            selectedMonth: "2026-07",
            budgetID: "budget",
            currentBudgetID: { "budget" },
            repository: repository
        )
        #expect(second == nil)
        await repository.finish()
        let loaded = await task.value
        #expect(loaded != nil)
        #expect(!workflow.isSubmitting)
    }

    @Test func budgetSwitchDuringTheWriteDropsTheOldBudgetsResult() async throws {
        let repository = DelayedVisibilityRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        var selectedBudgetID: String? = "budget"
        let task = Task { @MainActor in
            await workflow.setCategoryHidden(
                true,
                categoryID: "mortgage",
                groupHidden: false,
                selectedMonth: "2026-06",
                budgetID: "budget",
                currentBudgetID: { selectedBudgetID },
                repository: repository
            )
        }
        await repository.waitUntilStarted()
        selectedBudgetID = "other-budget"
        await repository.finish()
        let loaded = await task.value

        #expect(loaded == nil)
        #expect(!workflow.isSubmitting)
        #expect(workflow.errorMessage == nil)
    }

    // MARK: Guarded commit (shared by the compact and wide Budget layouts)

    @Test func commitHidesWithTheSharedBudgetThenRefreshesOnce() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let budgets = SwitchableBudgets("budget")
        var refreshes = 0
        await workflow.commitCategoryHidden(
            true, categoryID: "mortgage", groupHidden: false, month: "2026-06",
            budget: budgets.scope, repository: repository
        ) { refreshes += 1 }

        let recorded = try await repository.onlyCategoryHide()
        #expect(recorded.budgetID == "budget")
        #expect(recorded.month == "2026-06")
        #expect(refreshes == 1)
        #expect(workflow.errorMessage == nil)
    }

    @Test func commitWritesNothingWhileTheVisibleBudgetIsNotTheSelectedOne() async {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let budgets = SwitchableBudgets(visible: "budget", selected: "other")
        var refreshes = 0
        await workflow.commitCategoryHidden(
            true, categoryID: "mortgage", groupHidden: false, month: "2026-06",
            budget: budgets.scope, repository: repository
        ) { refreshes += 1 }
        await workflow.commitGroupHidden(
            true, group: expenseGroup, month: "2026-06", budget: budgets.scope, repository: repository
        ) { refreshes += 1 }
        await workflow.commitCategoryCarryover(
            true, category: rolloverCategory(isIncome: false), expectedMode: nil, month: "2026-06",
            budget: budgets.scope, repository: repository
        ) { refreshes += 1 }

        #expect(await repository.recordedCategoryHides().isEmpty)
        #expect(await repository.carryoverUpdateCount() == 0)
        #expect(refreshes == 0)
        #expect(workflow.errorMessage == nil)
    }

    @Test func commitDoesNotRefreshWhenTheSelectedBudgetChangesDuringTheWrite() async throws {
        let repository = DelayedVisibilityRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let budgets = SwitchableBudgets("budget")
        var refreshes = 0
        let task = Task { @MainActor in
            await workflow.commitCategoryHidden(
                true, categoryID: "mortgage", groupHidden: false, month: "2026-06",
                budget: budgets.scope, repository: repository
            ) { refreshes += 1 }
        }
        await repository.waitUntilStarted()
        budgets.selected = "other"
        await repository.finish()
        await task.value

        #expect(refreshes == 0)
        #expect(workflow.errorMessage == nil)
        #expect(!workflow.isSubmitting)
    }

    @Test func commitDoesNotRefreshWhenTheVisibleBudgetChangesDuringTheWrite() async throws {
        let repository = DelayedVisibilityRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let budgets = SwitchableBudgets("budget")
        var refreshes = 0
        let task = Task { @MainActor in
            await workflow.commitCategoryHidden(
                true, categoryID: "mortgage", groupHidden: false, month: "2026-06",
                budget: budgets.scope, repository: repository
            ) { refreshes += 1 }
        }
        await repository.waitUntilStarted()
        budgets.visible = "other"
        await repository.finish()
        await task.value

        #expect(refreshes == 0)
        #expect(!workflow.isSubmitting)
    }

    @Test func aFailedWriteForTheOldBudgetShowsNoErrorForTheNewOne() async {
        let repository = RecordingBudgetRepository(
            carryoverError: BudgetModeWriteError.budgetChanged, suspendsCarryover: true
        )
        let workflow = BudgetCategoryFlagWorkflow()
        let budgets = SwitchableBudgets("budget")
        var refreshes = 0
        let task = Task { @MainActor in
            await workflow.commitCategoryCarryover(
                true, category: rolloverCategory(isIncome: false), expectedMode: nil, month: "2026-06",
                budget: budgets.scope, repository: repository
            ) { refreshes += 1 }
        }
        await repository.waitUntilCarryoverStarted()
        budgets.selected = "other"
        await repository.resumeCarryover()
        await task.value

        #expect(workflow.errorMessage == nil)
        #expect(refreshes == 0)
    }

    @Test func aFailedCommitReportsTheErrorAndDoesNotRefresh() async {
        let repository = RecordingBudgetRepository(carryoverError: BudgetModeWriteError.budgetChanged)
        let workflow = BudgetCategoryFlagWorkflow()
        var refreshes = 0
        await workflow.commitCategoryCarryover(
            true, category: rolloverCategory(isIncome: false), expectedMode: nil, month: "2026-06",
            budget: SwitchableBudgets("budget").scope, repository: repository
        ) { refreshes += 1 }

        #expect(workflow.errorMessage == BudgetModeWriteError.budgetChanged.userFacingMessage)
        #expect(refreshes == 0)
    }

    @Test func commitCarryoverPassesTheLayoutsExpectedModeAndRefreshes() async throws {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        let mode = BudgetModeIdentity(storageID: "db-1", table: .envelope, revision: "r1")
        var refreshes = 0
        await workflow.commitCategoryCarryover(
            true, category: rolloverCategory(isIncome: false), expectedMode: mode, month: "2026-06",
            budget: SwitchableBudgets("budget").scope, repository: repository
        ) { refreshes += 1 }

        let recorded = try await repository.onlyCarryoverUpdate()
        #expect(recorded.expectedMode == mode)
        #expect(recorded.startMonth == "2026-06")
        #expect(refreshes == 1)
    }

    @Test func aMissingMonthReportsOpenABudgetFirstWithoutRefreshing() async {
        let repository = RecordingBudgetRepository()
        let workflow = BudgetCategoryFlagWorkflow()
        var refreshes = 0
        await workflow.commitCategoryHidden(
            true, categoryID: "mortgage", groupHidden: false, month: nil,
            budget: SwitchableBudgets("budget").scope, repository: repository
        ) { refreshes += 1 }

        #expect(workflow.errorMessage == "Open a budget first.")
        #expect(refreshes == 0)
    }
}

/// Visible and selected budget ids that a test can change mid-write.
@MainActor
final class SwitchableBudgets {
    var visible: String?
    var selected: String?

    init(_ both: String?) { visible = both; selected = both }
    init(visible: String?, selected: String?) { self.visible = visible; self.selected = selected }

    var scope: BudgetActionBudgetScope {
        BudgetActionBudgetScope(visible: { self.visible }, selected: { self.selected })
    }
}

private let expenseGroup = BudgetMonthCategoryGroup(
    id: "food", name: "Food", isIncome: false, hidden: false,
    budgeted: 0, spent: 0, balance: 0, categories: []
)

private func rolloverCategory(isIncome: Bool) -> BudgetMonthCategory {
    BudgetMonthCategory(
        id: isIncome ? "salary" : "groceries",
        name: isIncome ? "Salary" : "Groceries",
        isIncome: isIncome,
        hidden: false,
        groupID: isIncome ? "income" : "food",
        budgeted: 0,
        spent: 0,
        balance: 0,
        carryover: false
    )
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

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
        emptyLoadedMonth
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        emptyLoadedMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        actionSource: BudgetActionSource,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth? {
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
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
        didUpdate: @escaping @MainActor @Sendable () async -> Void
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
