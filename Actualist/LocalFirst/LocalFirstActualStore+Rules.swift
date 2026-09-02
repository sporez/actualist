import Foundation

extension LocalFirstActualStore {
    func cachedRules(budgetID: String) -> [ManagedRule]? {
        rulesByBudget[budgetID]
    }

    func refreshRules(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        rulesByBudget[budgetID] = try await database.fetchRules()
    }

    func ruleEditorOptions(budgetID: String) async throws -> RuleEditorOptions {
        try await requireDatabase(for: budgetID).fetchRuleEditorOptions()
    }

    func matchingTransactions(
        budgetID: String,
        draft: RuleDraft,
        limit: Int
    ) async throws -> RuleTransactionMatchPreview {
        try await requireDatabase(for: budgetID).fetchMatchingTransactions(for: draft, limit: limit)
    }

    func createRuleAndRefresh(budgetID: String, draft: RuleDraft) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.createRuleMessages(
            ruleID: UUID().uuidString,
            draft: draft,
            builder: &builder
        )
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .create)),
            source: .ui
        )
        try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func updateRuleAndRefresh(budgetID: String, ruleID: String, draft: RuleDraft) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.updateRuleMessages(
            ruleID: ruleID,
            draft: draft,
            builder: &builder
        )
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .update)),
            source: .ui
        )
        try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    func deleteRuleAndRefresh(budgetID: String, ruleID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.deleteRuleMessages(ruleID: ruleID, builder: &builder)
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .delete)),
            source: .ui
        )
        try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        await schedulePendingLocalMessageFlush(database: database, budgetID: budgetID)
    }

    private func reloadAfterRuleMutation(database: BudgetDatabase, budgetID: String) async throws {
        rulesByBudget[budgetID] = try await database.fetchRules()
        payeesByBudget[budgetID] = try await database.fetchPayeeManagementSnapshot()
            .settingCanUndo(lastPayeeUndoMessagesByBudget[budgetID]?.isEmpty == false)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }
}
