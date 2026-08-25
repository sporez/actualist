import Foundation

extension LocalFirstActualStore {
    func accountGroupManagementEnabled(budgetID: String) -> Bool {
        accountGroupManagementEnabledByBudget[budgetID] ?? false
    }

    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.createAccountGroupMessages(
            groupID: UUID().uuidString,
            name: name,
            builder: &builder
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    func renameAccountGroupAndRefresh(
        budgetID: String,
        groupID: String,
        name: String
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.renameAccountGroupMessages(
            groupID: groupID,
            name: name,
            builder: &builder
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.deleteAccountGroupMessages(
            groupID: groupID,
            builder: &builder
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    func moveAccountToGroupAndRefresh(
        budgetID: String,
        accountID: String,
        groupID: String?
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.moveAccountToGroupMessages(
            accountID: accountID,
            groupID: groupID,
            builder: &builder
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    func moveAccountGroupAndRefresh(
        budgetID: String,
        groupID: String,
        beforeGroupID: String?
    ) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.moveAccountGroupMessages(
            groupID: groupID,
            beforeGroupID: beforeGroupID,
            builder: &builder
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    private func commitAccountGroupMessages(
        _ messages: [ActualSyncDecodedMessage],
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        guard !messages.isEmpty else {
            return
        }
        _ = try await database.commitLocalSyncMessagesAndEnqueue(messages)
        try await reloadAfterAccountMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }
}
