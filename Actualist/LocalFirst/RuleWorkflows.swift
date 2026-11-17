import Foundation

/// Rules on the store: the rules cache refresh and its request revisions,
/// editor options, matching transactions, and rule writes with their
/// reloads. The store owns it; the rules cache (`rulesByBudget`) stays on
/// the store, which publishes it.
@MainActor
final class RuleWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore
    private var rulesCacheRevisionByBudget: [String: UInt64] = [:]
    private var nextRulesCacheRevision: UInt64 = 0

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// Called where the store clears its budget session.
    func resetRequestSession() { rulesCacheRevisionByBudget = [:] }

    func cachedRules(budgetID: String) -> [ManagedRule]? {
        store.rulesByBudget[budgetID]
    }

    func refreshRules(budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        try await refreshRulesCache(database: database, budgetID: budgetID)
    }

    func ruleEditorOptions(budgetID: String) async throws -> RuleEditorOptions {
        try await RuleSQL.fetchRuleEditorOptions(in: store.requireDatabase(for: budgetID))
    }

    func matchingTransactions(
        budgetID: String,
        draft: RuleDraft,
        limit: Int
    ) async throws -> RuleTransactionMatchPreview {
        try await RulePreviewSQL.fetchMatchingTransactions(for: draft, limit: limit, in: store.requireDatabase(for: budgetID))
    }

    func createRuleAndRefresh(budgetID: String, draft: RuleDraft) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await RuleSQL.createRuleMessages(
            ruleID: UUID().uuidString,
            draft: draft,
            builder: &builder,
            in: database
        )
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .create)),
            source: .ui
        )
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
    }

    func updateRuleAndRefresh(budgetID: String, ruleID: String, draft: RuleDraft) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await RuleSQL.updateRuleMessages(
            ruleID: ruleID,
            draft: draft,
            builder: &builder,
            in: database
        )
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .update)),
            source: .ui
        )
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
    }

    func deleteRuleAndRefresh(budgetID: String, ruleID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await RuleSQL.deleteRuleMessages(ruleID: ruleID, builder: &builder, in: database)
        _ = try await database.commitUserAction(
            messages,
            descriptor: .rule(RuleActionDescriptor(operation: .delete)),
            source: .ui
        )
        try await store.finishCommittedWrite(database: database, budgetID: budgetID) {
            try await reloadAfterRuleMutation(database: database, budgetID: budgetID)
        }
    }

    private func reloadAfterRuleMutation(database: BudgetDatabase, budgetID: String) async throws {
        store.schedules.invalidateScheduleCache(budgetID: budgetID)
        invalidateRulesCache(budgetID: budgetID)
        try await refreshRulesCache(database: database, budgetID: budgetID)
        try await store.payees.publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
        await store.refreshActionLogDiagnosticSnapshot(database: database)
    }

    func invalidateRulesCache(budgetID: String) {
        store.rulesByBudget[budgetID] = nil
        nextRulesCacheRevision &+= 1
        rulesCacheRevisionByBudget[budgetID] = nextRulesCacheRevision
    }

    func refreshRulesCache(database: BudgetDatabase, budgetID: String) async throws {
        let generation = store.budgetSessionGeneration
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        nextRulesCacheRevision &+= 1
        let revision = nextRulesCacheRevision
        rulesCacheRevisionByBudget[budgetID] = revision
        let loaded = try await RuleSQL.fetchRules(in: database)
        #if DEBUG
        try await store.testSeams?.rulesReadHook?(budgetID)
        #endif
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        guard rulesCacheRevisionByBudget[budgetID] == revision else {
            throw CancellationError()
        }
        store.rulesByBudget[budgetID] = loaded
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
        try await store.payees.publishPayeeManagementSnapshot(database: database, budgetID: budgetID)
    }
}

extension RuleWorkflows: RuleRepositoryProtocol { }
