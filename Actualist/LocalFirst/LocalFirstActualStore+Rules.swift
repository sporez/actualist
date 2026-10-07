import Foundation

typealias RulesReadHook = @MainActor @Sendable (_ budgetID: String) async throws -> Void

extension LocalFirstActualStore {
    func cachedRules(budgetID: String) -> [ManagedRule]? {
        rulesByBudget[budgetID]
    }

    func refreshRules(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        try await refreshRulesCache(database: database, budgetID: budgetID)
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
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
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
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
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
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
    }

    private func reloadAfterRuleMutation(database: BudgetDatabase, budgetID: String) async throws {
        invalidateScheduleCache(budgetID: budgetID)
        invalidateRulesCache(budgetID: budgetID)
        try await refreshRulesCache(database: database, budgetID: budgetID)
        try await publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
        await refreshActionLogDiagnosticSnapshot(database: database)
    }

    func invalidateRulesCache(budgetID: String) {
        rulesByBudget[budgetID] = nil
        nextRulesCacheRevision &+= 1
        rulesCacheRevisionByBudget[budgetID] = nextRulesCacheRevision
    }

    func refreshRulesCache(database: BudgetDatabase, budgetID: String) async throws {
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        nextRulesCacheRevision &+= 1
        let revision = nextRulesCacheRevision
        rulesCacheRevisionByBudget[budgetID] = revision
        let loaded = try await database.fetchRules()
        try await rulesReadHook?(budgetID)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard rulesCacheRevisionByBudget[budgetID] == revision else {
            throw CancellationError()
        }
        rulesByBudget[budgetID] = loaded
    }

    /// Rules and payee refresh inside a durable write tail, for writes that
    /// create learning rules. A newer refresh superseding this one is success
    /// because that refresh publishes; any other failure throws and the tail
    /// reports `refreshPending`. Mirrors `refreshSchedulesAfterWrite`.
    func refreshRulesAndPayeesAfterLearning(
        learningIDs: Set<String>,
        database: BudgetDatabase,
        budgetID: String
    ) async throws {
        guard !learningIDs.isEmpty else { return }
        do {
            try await refreshRulesCache(database: database, budgetID: budgetID)
        } catch is CancellationError where !Task.isCancelled {
            // Superseded (or session retired, which the payee publish rechecks).
        }
        try await publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
    }
}
