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
    func budgetHoldReview(budgetID: String, month: String) async throws -> BudgetHoldReview
    func applyBudgetHoldAndRefresh(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        budgetID: String
    ) async throws -> LoadedBudgetMonth?
    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity?,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth?
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
    func categoryNeedsTransfer(categoryID: String, budgetID: String) async throws -> Bool
    func deleteCategoryAndRefresh(
        categoryID: String,
        transferCategoryID: String?,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func deleteCategoryGroupAndRefresh(
        groupID: String,
        transferCategoryID: String?,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth
    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity?,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth
    func applyReviewedBudgetTemplateAndRefresh(
        reviewRevision: BudgetTemplateReviewRevision,
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
    func previewBudgetTemplatePair(
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreviewPair
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth?
    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity?,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth?
    // History: local money-flow gesture log and LIFO undo.
    func budgetModeIdentity(budgetID: String) async throws -> BudgetModeIdentity?
    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord]
    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String]
    func budgetActionUndoPreview(actionID: String, budgetID: String) async throws -> BudgetActionUndoPreview
    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws
}

extension BudgetRepositoryProtocol {
    func budgetHoldReview(budgetID: String, month: String) async throws -> BudgetHoldReview {
        throw LocalFirstError.unsupportedWrite
    }

    func applyBudgetHoldAndRefresh(
        command: BudgetHoldCommand,
        review: BudgetHoldReview,
        budgetID: String
    ) async throws -> LoadedBudgetMonth? {
        throw LocalFirstError.unsupportedWrite
    }

    func applyReviewedBudgetTemplateAndRefresh(
        reviewRevision: BudgetTemplateReviewRevision,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

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

    func categoryNeedsTransfer(categoryID: String, budgetID: String) async throws -> Bool {
        throw LocalFirstError.unsupportedWrite
    }

    func deleteCategoryAndRefresh(categoryID: String, transferCategoryID: String?, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        throw LocalFirstError.unsupportedWrite
    }

    func deleteCategoryGroupAndRefresh(groupID: String, transferCategoryID: String?, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
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

    func previewBudgetTemplatePair(
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreviewPair {
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
    /// Largest accepted single move in minor units. It keeps the per-category
    /// budgeted sums far from `Int` overflow.
    static let maximumAmount = 1_000_000_000_000

    /// How the store treats the amount. A plain move writes it as given. A cover is limited to what
    /// its source has left, and a move from To Budget into a category (`transferAvailable`) to what
    /// To Budget has, floored at zero, as Actual's cover and transfer-available handlers are.
    enum Kind: Hashable, Sendable {
        case move
        case cover
        case transferAvailable
    }

    let fromCategoryID: String?
    let toCategoryID: String?
    let amount: Int
    var kind: Kind = .move

    /// A move between two categories or into To Budget is a plain move. One that takes from To Budget
    /// into a category is a transfer-available, limited to what To Budget has at commit.
    static func move(fromCategoryID: String?, toCategoryID: String?, amount: Int) -> BudgetMoveMoneyCommand {
        BudgetMoveMoneyCommand(
            fromCategoryID: fromCategoryID,
            toCategoryID: toCategoryID,
            amount: amount,
            kind: fromCategoryID == nil && toCategoryID != nil ? .transferAvailable : .move
        )
    }

    /// The command a move may commit when its source (a category, or To Budget when `fromCategoryID`
    /// is nil) has `sourceAvailable` left. A cover with nothing to move is nil. A transfer-available
    /// keeps a zero amount, because Actual still writes the destination's budget row.
    func limited(toSourceAvailable sourceAvailable: Int) -> BudgetMoveMoneyCommand? {
        let limitedAmount: Int
        switch kind {
        case .move:
            return self
        case .cover:
            limitedAmount = min(amount, sourceAvailable)
            guard amount > 0, limitedAmount > 0 else { return nil }
        case .transferAvailable:
            limitedAmount = max(min(amount, sourceAvailable), 0)
        }
        return BudgetMoveMoneyCommand(
            fromCategoryID: fromCategoryID, toCategoryID: toCategoryID, amount: limitedAmount, kind: kind
        )
    }
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
