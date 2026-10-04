import Foundation

extension ActualBudget {
    /// The selected budget rebuilt from persisted settings when no discovered
    /// `ActualBudget` is available (offline launch, background work, intents).
    /// Callers keep their own guards (for example a selected budget id); nil
    /// means no local-first file is recorded.
    static func reconstructedFromSettings(_ settings: AppSettings) -> ActualBudget? {
        guard let fileID = settings.selectedLocalFirstFileID else { return nil }
        return ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: settings.selectedLocalFirstGroupID,
            name: settings.selectedBudgetName ?? "Selected Budget",
            state: nil
        )
    }

    /// Lookup precedence shared by background refresh and Shortcuts: the
    /// in-memory selected budget, then the discovered list, then settings.
    static func resolved(
        budgetID: String,
        selectedBudget: ActualBudget?,
        budgets: [ActualBudget],
        settings: AppSettings
    ) -> ActualBudget? {
        if let selectedBudget, selectedBudget.syncID == budgetID {
            return selectedBudget
        }
        if let budget = budgets.first(where: { $0.syncID == budgetID }) {
            return budget
        }
        return reconstructedFromSettings(settings)
    }
}
