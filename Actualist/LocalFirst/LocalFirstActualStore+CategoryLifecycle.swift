import Foundation

extension LocalFirstActualStore {
    func createCategoryAndRefresh(name: String, groupID: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await database.createCategoryMessages(
                categoryID: UUID().uuidString, name: name, groupID: groupID, builder: &builder
            )
        }
    }

    func createCategoryGroupAndRefresh(name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await database.createCategoryGroupMessages(
                groupID: UUID().uuidString, name: name, builder: &builder
            )
        }
    }

    func renameCategoryAndRefresh(categoryID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await database.renameCategoryMessages(categoryID: categoryID, name: name, builder: &builder)
        }
    }

    func renameCategoryGroupAndRefresh(groupID: String, name: String, budgetID: String, month: String) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await database.renameCategoryGroupMessages(groupID: groupID, name: name, builder: &builder)
        }
    }

    func applyCategoryOutlineAndRefresh(
        draft: BudgetCategoryOutlineCommand,
        budgetID: String,
        month: String
    ) async throws -> LoadedBudgetMonth {
        try await commitCategoryLifecycle(budgetID: budgetID, month: month) { database, builder in
            try await database.applyCategoryOutlineMessages(draft, builder: &builder)
        }
    }

    private func commitCategoryLifecycle(
        budgetID: String,
        month: String,
        messages: (BudgetDatabase, inout LocalFirstSyncMessageBuilder) async throws -> [ActualSyncDecodedMessage]
    ) async throws -> LoadedBudgetMonth {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await messages(database, &builder)
        if !messages.isEmpty {
            _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
            try await reloadAfterBudgetMutation(database: database, budgetID: budgetID)
            await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
        }
        return try await budgetMonth(budgetID: budgetID, selectedMonth: month)
    }
}
