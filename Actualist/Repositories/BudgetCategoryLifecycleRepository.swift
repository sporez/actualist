import Foundation

/// Category and category-group lifecycle: create, rename, reorder and delete.
protocol BudgetCategoryLifecycleRepositoryProtocol: Sendable {
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
}

struct BudgetCategoryOutlineCommand: Hashable, Sendable {
    struct Group: Hashable, Sendable {
        let id: String
        let categoryIDs: [String]
    }

    /// One reorder drag, as Actual's `category-move` / `category-group-move` receive it.
    enum Move: Hashable, Sendable {
        case category(id: String, toGroupID: String, beforeCategoryID: String?)
        case group(id: String, beforeGroupID: String?)
    }

    let groups: [Group]
    /// The drags in the order they were made; the store replays each one on the stored sort orders.
    let moves: [Move]
}
