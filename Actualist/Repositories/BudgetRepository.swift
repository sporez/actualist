import Foundation

protocol BudgetRepositoryProtocol: Sendable {
    func budgets() async throws -> [ActualBudget]
    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth
    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth
    func assignCategoryBudgetAndRefresh(
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setCategoryCarryoverAndRefresh(
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func applyBudgetTemplateAndRefresh(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func moveMoneyAndRefresh(
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
    func moveMoneyAndRefresh(
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping () async -> Void
    ) async throws -> LoadedBudgetMonth
}

struct LoadedBudgetMonth: Equatable {
    let availableMonths: [String]
    let selectedMonth: String
    let month: BudgetMonth
    let alerts: [BudgetMonthAlert]
    var currency: BudgetCurrency = .usd
}

struct BudgetMoveMoneyCommand: Hashable, Sendable {
    let fromCategoryID: String?
    let toCategoryID: String?
    let amount: Int
}

enum BudgetTemplateApplicationMode: String, Codable, Hashable, Sendable {
    case fillEmpty = "fill-empty"
    case overwrite
}

struct BudgetTemplateCommand: Hashable, Sendable {
    let mode: BudgetTemplateApplicationMode
    let categoryIDs: [String]

    static let fillEmpty = BudgetTemplateCommand(mode: .fillEmpty, categoryIDs: [])
    static let overwrite = BudgetTemplateCommand(mode: .overwrite, categoryIDs: [])

    static func category(_ categoryID: String) -> BudgetTemplateCommand {
        BudgetTemplateCommand(mode: .overwrite, categoryIDs: [categoryID])
    }
}
