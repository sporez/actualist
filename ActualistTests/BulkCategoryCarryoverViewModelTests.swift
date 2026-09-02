import Foundation
import Testing
@testable import Actualist

@MainActor
struct BulkCategoryCarryoverViewModelTests {
    @Test func statusIncludesHiddenExpensesAndExcludesIncomeCategories() throws {
        let loaded = makeLoadedMonth(
            expenseCarryover: [false, true, false],
            hiddenExpenseIndex: 1,
            incomeCarryover: true
        )

        let status = BulkCategoryCarryoverStatus(loadedMonth: loaded)

        #expect(status.categoryCount == 3)
        #expect(status.enabledCount == 1)
        #expect(!status.allEnabled)
        #expect(status.canEnableAll)
        #expect(status.canDisableAll)
        #expect(status.detail == "On for 1 of 3 categories")
        #expect(status.monthTitle == "July 2026")

        let none = BulkCategoryCarryoverStatus(
            loadedMonth: makeLoadedMonth(expenseCarryover: [false, false])
        )
        let all = BulkCategoryCarryoverStatus(
            loadedMonth: makeLoadedMonth(expenseCarryover: [true, true])
        )
        #expect(none.detail == "Off for all 2 categories")
        #expect(!none.allEnabled)
        #expect(all.detail == "On for all 2 categories")
        #expect(all.allEnabled)
    }

    @Test func loadThenEnableAllUsesTheLoadedMonthAndAppliesReturnedState() async throws {
        let repository = BulkCarryoverRepository(
            loaded: makeLoadedMonth(expenseCarryover: [false, true]),
            updated: makeLoadedMonth(expenseCarryover: [true, true])
        )
        let model = BulkCategoryCarryoverViewModel()

        await model.load(
            budgetID: "budget",
            preferredMonth: "2026-07",
            repository: repository
        )
        await model.setAll(
            carryover: true,
            budgetID: "budget",
            repository: repository
        )

        #expect(model.status?.allEnabled == true)
        #expect(model.errorMessage == nil)
        #expect(!model.isApplying)
        let command = try await repository.onlyCommand()
        #expect(command.carryover)
        #expect(command.budgetID == "budget")
        #expect(command.startMonth == "2026-07")
    }

    @Test func failedDisablePreservesTheLoadedStateAndShowsTheError() async {
        let repository = BulkCarryoverRepository(
            loaded: makeLoadedMonth(expenseCarryover: [true, true]),
            updated: makeLoadedMonth(expenseCarryover: [false, false]),
            mutationError: BulkCarryoverTestError.failed
        )
        let model = BulkCategoryCarryoverViewModel()

        await model.load(
            budgetID: "budget",
            preferredMonth: "2026-07",
            repository: repository
        )
        await model.setAll(
            carryover: false,
            budgetID: "budget",
            repository: repository
        )

        #expect(model.status?.allEnabled == true)
        #expect(model.errorMessage == "Bulk rollover failed")
        #expect(!model.isApplying)
    }

    @Test func resetDropsAStaleMutationResult() async {
        let repository = BulkCarryoverRepository(
            loaded: makeLoadedMonth(expenseCarryover: [false, true]),
            updated: makeLoadedMonth(expenseCarryover: [true, true]),
            suspendsMutation: true
        )
        let model = BulkCategoryCarryoverViewModel()
        await model.load(
            budgetID: "budget",
            preferredMonth: "2026-07",
            repository: repository
        )

        let task = Task {
            await model.setAll(
                carryover: true,
                budgetID: "budget",
                repository: repository
            )
        }
        await repository.waitUntilMutationStarted()
        model.reset()
        await repository.resumeMutation()
        await task.value

        #expect(model.status == nil)
        #expect(model.isLoading)
    }

    private func makeLoadedMonth(
        expenseCarryover: [Bool],
        hiddenExpenseIndex: Int? = nil,
        incomeCarryover: Bool = false
    ) -> LoadedBudgetMonth {
        let expenseCategories = expenseCarryover.enumerated().map { index, carryover in
            makeCategory(
                id: "expense-\(index)",
                isIncome: false,
                hidden: index == hiddenExpenseIndex,
                carryover: carryover,
                groupID: "expenses"
            )
        }
        let incomeCategory = makeCategory(
            id: "income",
            isIncome: true,
            hidden: false,
            carryover: incomeCarryover,
            groupID: "income"
        )
        let groups = [
            makeGroup(id: "expenses", isIncome: false, categories: expenseCategories),
            makeGroup(id: "income", isIncome: true, categories: [incomeCategory])
        ]
        let month = BudgetMonth(
            month: "2026-07",
            incomeAvailable: 0,
            lastMonthOverspent: 0,
            forNextMonth: 0,
            totalBudgeted: 0,
            toBudget: 0,
            fromLastMonth: 0,
            totalIncome: 0,
            totalSpent: 0,
            totalBalance: 0,
            categoryGroups: groups
        )
        return LoadedBudgetMonth(
            availableMonths: ["2026-07"],
            selectedMonth: "2026-07",
            month: month,
            alerts: []
        )
    }

    private func makeGroup(
        id: String,
        isIncome: Bool,
        categories: [BudgetMonthCategory]
    ) -> BudgetMonthCategoryGroup {
        BudgetMonthCategoryGroup(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: false,
            budgeted: 0,
            spent: 0,
            balance: 0,
            categories: categories
        )
    }

    private func makeCategory(
        id: String,
        isIncome: Bool,
        hidden: Bool,
        carryover: Bool,
        groupID: String
    ) -> BudgetMonthCategory {
        BudgetMonthCategory(
            id: id,
            name: id,
            isIncome: isIncome,
            hidden: hidden,
            groupID: groupID,
            budgeted: 0,
            spent: 0,
            balance: 0,
            carryover: carryover
        )
    }
}

private struct BulkCarryoverCommand: Equatable, Sendable {
    let carryover: Bool
    let budgetID: String
    let startMonth: String
}

private enum BulkCarryoverTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Bulk rollover failed" }
}

private actor BulkCarryoverRepository: BudgetRepositoryProtocol {
    private let loaded: LoadedBudgetMonth
    private let updated: LoadedBudgetMonth
    private let mutationError: Error?
    private let suspendsMutation: Bool
    private var commands: [BulkCarryoverCommand] = []
    private var mutationContinuation: CheckedContinuation<Void, Never>?
    private var mutationStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var mutationStarted = false

    init(
        loaded: LoadedBudgetMonth,
        updated: LoadedBudgetMonth,
        mutationError: Error? = nil,
        suspendsMutation: Bool = false
    ) {
        self.loaded = loaded
        self.updated = updated
        self.mutationError = mutationError
        self.suspendsMutation = suspendsMutation
    }

    func waitUntilMutationStarted() async {
        if mutationStarted { return }
        await withCheckedContinuation { mutationStartedWaiters.append($0) }
    }

    func resumeMutation() {
        mutationContinuation?.resume()
        mutationContinuation = nil
    }

    func onlyCommand() throws -> BulkCarryoverCommand {
        try #require(commands.first)
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        loaded
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        loaded
    }

    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        commands.append(BulkCarryoverCommand(
            carryover: carryover,
            budgetID: budgetID,
            startMonth: startMonth
        ))
        mutationStarted = true
        mutationStartedWaiters.forEach { $0.resume() }
        mutationStartedWaiters = []
        if suspendsMutation {
            await withCheckedContinuation { mutationContinuation = $0 }
        }
        if let mutationError { throw mutationError }
        return updated
    }

    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth { loaded }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}
}
