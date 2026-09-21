import Testing
@testable import Actualist

@MainActor
struct BudgetCategoryOrganizationWorkflowTests {
    @Test func createAndRenameSubmitTrimmedCommands() async throws {
        let repository = CategoryLifecycleRecordingRepository()
        let workflow = BudgetCategoryOrganizationWorkflow()
        let expense = group("expense", "Expenses", false, [])
        let category = category("food", "Food", false, "expense")

        _ = await workflow.createCategory(
            name: "  Fuel  ", group: expense, isTrackingBudget: false,
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        )
        _ = await workflow.renameCategory(
            category, name: " Dining ", isTrackingBudget: false,
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        )

        #expect(await repository.createdCategories == [.init(name: "Fuel", groupID: "expense")])
        #expect(await repository.renamedCategories == [.init(id: "food", name: "Dining")])
    }

    @Test func emptyNamesAndEnvelopeIncomeNeverReachRepository() async {
        let repository = CategoryLifecycleRecordingRepository()
        let workflow = BudgetCategoryOrganizationWorkflow()
        let income = group("income", "Income", true, [])

        #expect(await workflow.createGroup(name: "  ", selectedMonth: "2026-07", budgetID: "budget", repository: repository) == nil)
        #expect(workflow.errorMessage == "Category group name cannot be empty.")
        #expect(await workflow.createCategory(
            name: "Salary", group: income, isTrackingBudget: false,
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        ) == nil)
        #expect(workflow.errorMessage == "Income categories cannot be managed in an envelope budget.")
        #expect(await repository.createdCategories.isEmpty)
    }

    @Test func inFlightSubmitIsIgnoredAndCancelledGenerationDropsResult() async {
        let repository = CategoryLifecycleRecordingRepository(suspendCreates: true)
        let workflow = BudgetCategoryOrganizationWorkflow()
        let first = Task {
            await workflow.createGroup(name: "Bills", selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        }
        await repository.waitUntilCreateStarted()
        let second = await workflow.createGroup(name: "Other", selectedMonth: "2026-07", budgetID: "budget", repository: repository)
        #expect(second == nil)
        workflow.cancel()
        await repository.finishCreate()
        #expect(await first.value == nil)
        #expect(!workflow.isSubmitting)
        #expect(await repository.createdGroups == ["Bills"])
    }
}

actor CategoryLifecycleRecordingRepository: BudgetRepositoryProtocol {
    struct CreatedCategory: Equatable, Sendable { let name: String; let groupID: String }
    struct RenamedEntity: Equatable, Sendable { let id: String; let name: String }

    private(set) var createdCategories: [CreatedCategory] = []
    private(set) var createdGroups: [String] = []
    private(set) var renamedCategories: [RenamedEntity] = []
    private(set) var renamedGroups: [RenamedEntity] = []
    private(set) var outlines: [BudgetCategoryOutlineCommand] = []
    private let suspendCreates: Bool
    private var createStarted = false
    private var createStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var createContinuation: CheckedContinuation<Void, Never>?

    init(suspendCreates: Bool = false) {
        self.suspendCreates = suspendCreates
    }

    func waitUntilCreateStarted() async {
        if createStarted { return }
        await withCheckedContinuation { createStartedWaiters.append($0) }
    }

    func finishCreate() {
        createContinuation?.resume()
        createContinuation = nil
    }

    func createCategoryAndRefresh(name: String, groupID: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        createdCategories.append(.init(name: name, groupID: groupID))
        return emptyCategoryLifecycleMonth
    }

    func createCategoryGroupAndRefresh(name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        createdGroups.append(name)
        if suspendCreates {
            createStarted = true
            createStartedWaiters.forEach { $0.resume() }
            createStartedWaiters = []
            await withCheckedContinuation { createContinuation = $0 }
        }
        return emptyCategoryLifecycleMonth
    }

    func renameCategoryAndRefresh(categoryID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        renamedCategories.append(.init(id: categoryID, name: name))
        return emptyCategoryLifecycleMonth
    }

    func renameCategoryGroupAndRefresh(groupID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        renamedGroups.append(.init(id: groupID, name: name))
        return emptyCategoryLifecycleMonth
    }

    func applyCategoryOutlineAndRefresh(draft: BudgetCategoryOutlineCommand, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        outlines.append(draft)
        return emptyCategoryLifecycleMonth
    }

    func budgets() async throws -> [ActualBudget] { [] }
    func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity?, categoryID: String, budgeted: Int, budgetID: String, month: String, didAssign: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?, categoryID: String, carryover: Bool, budgetID: String, startMonth: String, didSetCarryover: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?, carryover: Bool, budgetID: String, startMonth: String) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func setCategoryHiddenAndRefresh(categoryID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func setCategoryGroupHiddenAndRefresh(groupID: String, hidden: Bool, budgetID: String, month: String, didUpdate: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity?, command: BudgetTemplateCommand, budgetID: String, month: String, didApply: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?, command: BudgetMoveMoneyCommand, budgetID: String, month: String, didMove: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?, commands: [BudgetMoveMoneyCommand], budgetID: String, month: String, didMove: @escaping @MainActor @Sendable () async -> Void) async throws -> LoadedBudgetMonth { emptyCategoryLifecycleMonth }
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview { .init(actionID: actionID, month: "", entries: [], block: nil) }
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}
}

private let emptyCategoryLifecycleMonth = LoadedBudgetMonth(
    availableMonths: ["2026-07"], selectedMonth: "2026-07",
    month: BudgetMonth(
        month: "2026-07", incomeAvailable: 0, lastMonthOverspent: 0, forNextMonth: 0,
        totalBudgeted: 0, toBudget: 0, fromLastMonth: 0, totalIncome: 0,
        totalSpent: 0, totalBalance: 0, categoryGroups: []
    ),
    alerts: []
)

private func group(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ categories: [BudgetMonthCategory]
) -> BudgetMonthCategoryGroup {
    BudgetMonthCategoryGroup(
        id: id, name: name, isIncome: isIncome, hidden: false,
        budgeted: 0, spent: 0, balance: 0, categories: categories
    )
}

private func category(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ groupID: String
) -> BudgetMonthCategory {
    BudgetMonthCategory(
        id: id, name: name, isIncome: isIncome, hidden: false, groupID: groupID,
        budgeted: 0, spent: 0, balance: 0, carryover: false
    )
}
