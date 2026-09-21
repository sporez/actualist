import Foundation

/// Local-first budget reads and writes. Completions run on the main actor so
/// UI refresh hooks can cross this Sendable seam into the store.
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
    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity?,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity?,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth
    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func createCategoryAndRefresh(
        name: String,
        groupID: String,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func createCategoryGroupAndRefresh(
        name: String,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func renameCategoryAndRefresh(
        categoryID: String,
        name: String,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func renameCategoryGroupAndRefresh(
        groupID: String,
        name: String,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func applyCategoryOutlineAndRefresh(
        draft: BudgetCategoryOutlineCommand,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity?,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
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
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    // History: local money-flow gesture log and LIFO undo.
    func budgetModeIdentity(budgetID: String) async throws -> BudgetModeIdentity?
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord]
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String]
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws
}

extension BudgetRepositoryProtocol {
    func budgetModeIdentity(budgetID: String) async throws -> BudgetModeIdentity? {
        nil
    }

    func createCategoryAndRefresh(name: String, groupID: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func createCategoryGroupAndRefresh(name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func renameCategoryAndRefresh(categoryID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func renameCategoryGroupAndRefresh(groupID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func applyCategoryOutlineAndRefresh(draft: BudgetCategoryOutlineCommand, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

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
    var modeIdentity: BudgetModeIdentity? = nil
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

struct BudgetCategoryOutlineCommand: Hashable, Sendable {
    struct Group: Hashable, Sendable {
        let id: String
        let categoryIDs: [String]
    }

    let groups: [Group]
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
