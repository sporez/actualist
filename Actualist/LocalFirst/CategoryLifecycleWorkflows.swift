import Foundation

/// Category and category-group lifecycle on the store: create, rename,
/// reorder and delete, each with the reload that follows. The store owns it.
@MainActor
final class CategoryLifecycleWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func createCategoryAndRefresh(name: String, groupID: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategorySQL.createCategoryMessages(
                categoryID: UUID().uuidString, name: name, groupID: groupID, builder: &builder,
                in: database
            )
        }
    }

    func createCategoryGroupAndRefresh(name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategorySQL.createCategoryGroupMessages(
                groupID: UUID().uuidString, name: name, builder: &builder,
                in: database
            )
        }
    }

    func renameCategoryAndRefresh(categoryID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategorySQL.renameCategoryMessages(categoryID: categoryID, name: name, builder: &builder, in: database)
        }
    }

    func renameCategoryGroupAndRefresh(groupID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategorySQL.renameCategoryGroupMessages(groupID: groupID, name: name, builder: &builder, in: database)
        }
    }

    func applyCategoryOutlineAndRefresh(
        draft: BudgetCategoryOutlineCommand,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategorySQL.applyCategoryOutlineMessages(draft, builder: &builder, in: database)
        }
    }

    func categoryNeedsTransfer(categoryID: String, budgetID: String) async throws -> Bool {
        let database = try store.requireDatabase(for: budgetID)
        return try await CategoryDeletionSQL.categoryNeedsTransfer(categoryID: categoryID, in: database)
    }

    func deleteCategoryAndRefresh(
        categoryID: String,
        transferCategoryID: String?,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategoryDeletionSQL.deleteCategoryMessages(
                categoryID: categoryID, transferCategoryID: transferCategoryID, builder: &builder,
                in: database
            )
        }
    }

    func deleteCategoryGroupAndRefresh(
        groupID: String,
        transferCategoryID: String?,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await CategoryDeletionSQL.deleteCategoryGroupMessages(
                groupID: groupID, transferCategoryID: transferCategoryID, builder: &builder,
                in: database
            )
        }
    }

    private func commitCategoryLifecycle(
        budgetID: String,
        month: String,
        messages: (BudgetDatabase, inout LocalFirstSyncMessageBuilder) async throws -> [ActualSyncDecodedMessage]
    ) async throws -> LoadedBudgetMonth {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await messages(database, &builder)
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
            try await store.finishCommittedBudgetWrite(database: database, budgetID: budgetID)
        }
        return try await store.budgetMonth(budgetID: budgetID, selectedMonth: month)
    }
}

extension CategoryLifecycleWorkflows: BudgetCategoryLifecycleRepositoryProtocol { }
