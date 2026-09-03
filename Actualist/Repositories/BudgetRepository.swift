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
    func setAllExpenseCategoryCarryoverAndRefresh(
        carryover: Bool,
        budgetID: String,
        startMonth: String
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
    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun
    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot
    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot
    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview
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
    // History: local money-flow gesture log and LIFO undo.
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord]
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String]
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws
}

extension BudgetRepositoryProtocol {
    func setCategoryTemplatesAndRefresh(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func dryRunCategoryTemplate(
        categoryID: String,
        drafts: [BudgetTemplateDraft],
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateCategoryDryRun {
        throw LocalFirstError.unsupportedWrite
    }

    func categoryTemplateEditorSnapshot(
        categoryID: String,
        budgetID: String
    ) async throws -> BudgetTemplateEditorSnapshot {
        throw LocalFirstError.unsupportedWrite
    }

    func categoryTemplateBrowserSnapshot(
        budgetID: String
    ) async throws -> BudgetTemplateBrowserSnapshot {
        throw LocalFirstError.unsupportedWrite
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        throw LocalFirstError.unsupportedWrite
    }
}

struct LoadedBudgetMonth: Equatable {
    let availableMonths: [String]
    let selectedMonth: String
    let month: BudgetMonth
    let alerts: [BudgetMonthAlert]
    var currency: BudgetCurrency = .usd
    /// Envelope (false, the Actual default) vs tracking (true). Drives the
    /// overspent hidden-category rule: envelope keeps hidden overspent in the
    /// alert and Cover sheet; tracking drops them, matching Actual web.
    var isTrackingBudget: Bool = false
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
