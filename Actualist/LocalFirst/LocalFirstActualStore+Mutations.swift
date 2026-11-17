import Foundation

extension LocalFirstActualStore {
    /// Actual's running-balance preferences (`RunningBalancePreference`), so
    /// the setting follows the budget to both web layouts. The current column
    /// layout is read inside the commit. Last write wins; History records nothing.
    func setShowsRunningBalance(budgetID: String, accountID: String, enabled: Bool) async throws {
        let database = try requireDatabase(for: budgetID)
        let written = try await database.commitSyncedPreferences(
            reading: RunningBalancePreference.keys(accountID: accountID)
        ) { stored in
            RunningBalancePreference.writes(
                enabled: enabled,
                accountID: accountID,
                current: RunningBalancePreference.values(stored, accountID: accountID)
            )
        }
        guard written else { return }
        try await finishCommittedWrite(database: database, budgetID: budgetID) {
            try await refreshLoadedTransactionFeedCaches(database: database, budgetID: budgetID)
        }
    }

    func previewRules(for draft: TransactionDraft, budgetID: String) async throws -> TransactionRulePreview {
        let database = try requireDatabase(for: budgetID)
        return try await RulePreviewSQL.previewRules(for: draft, in: database)
    }
}
