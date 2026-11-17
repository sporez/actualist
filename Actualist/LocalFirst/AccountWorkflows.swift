import Foundation

/// Accounts on the store: the account and account-group reads, creating an
/// account and the account-group writes with the reload that follows. The
/// store owns it; the account caches and their reload tail stay on the store,
/// which other domains' writes also refresh.
@MainActor
final class AccountWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    func accountDisplays(budgetID: String) -> [AccountDisplay] {
        store.accountsByBudget[budgetID] ?? []
    }

    func accountGroups(budgetID: String) -> [ActualAccountGroup] {
        store.accountGroupsByBudget[budgetID] ?? []
    }

    func refreshAccountsWithBalances(budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        try await store.reloadAccountCaches(database: database, budgetID: budgetID)
    }

    func createAccountAndRefresh(
        budgetID: String,
        name: String,
        offbudget: Bool,
        actionSource: BudgetActionSource = .ui
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let accountID = UUID().uuidString
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountSQL.createAccountMessages(
            accountID: accountID,
            name: name,
            offbudget: offbudget,
            builder: &builder,
            in: database
        )

        _ = try await database.commitUserAction(
            messages,
            descriptor: .account(AccountActionDescriptor(name: name, offbudget: offbudget)),
            source: actionSource
        )
        try await store.finishCommittedAccountWrite(database: database, budgetID: budgetID)
    }

    func createAccountGroupAndRefresh(budgetID: String, name: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountGroupSQL.createAccountGroupMessages(
            groupID: UUID().uuidString,
            name: name,
            builder: &builder,
            in: database
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
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountGroupSQL.renameAccountGroupMessages(
            groupID: groupID,
            name: name,
            builder: &builder,
            in: database
        )
        try await commitAccountGroupMessages(
            messages,
            database: database,
            budgetID: budgetID
        )
    }

    func deleteAccountGroupAndRefresh(budgetID: String, groupID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountGroupSQL.deleteAccountGroupMessages(
            groupID: groupID,
            builder: &builder,
            in: database
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
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountGroupSQL.moveAccountToGroupMessages(
            accountID: accountID,
            groupID: groupID,
            builder: &builder,
            in: database
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
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await AccountGroupSQL.moveAccountGroupMessages(
            groupID: groupID,
            beforeGroupID: beforeGroupID,
            builder: &builder,
            in: database
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
        try await store.finishCommittedAccountWrite(database: database, budgetID: budgetID)
    }
}

extension AccountWorkflows: AccountRepositoryProtocol { }
