import Foundation

/// Per-device expand/collapse choices for budget category groups. Like
/// Actual's `budget.collapsed` local preference, they are kept per budget on
/// this device and never synced. A group without a recorded choice starts
/// expanded unless it is hidden.
struct BudgetGroupExpansion: Codable, Equatable, Sendable {
    private(set) var choices: [String: Bool]

    init(choices: [String: Bool] = [:]) {
        self.choices = choices
    }

    /// Income groups only have rows in a tracking budget.
    func expandedIDs(
        in groups: [BudgetMonthCategoryGroup],
        isTrackingBudget: Bool
    ) -> Set<String> {
        Set(
            groups
                .filter { group in
                    (!group.isIncome || isTrackingBudget)
                        && (choices[group.id] ?? (group.hidden != true))
                }
                .map(\.id)
        )
    }

    /// Records one choice and forgets choices for groups that no longer exist,
    /// so deleted groups do not accumulate.
    mutating func record(
        isExpanded: Bool,
        groupID: String,
        liveGroupIDs: Set<String>
    ) {
        choices = choices.filter { liveGroupIDs.contains($0.key) }
        choices[groupID] = isExpanded
    }
}

/// Where Budget models persist `BudgetGroupExpansion`. Production uses the
/// app settings; models without a store keep expansion in memory only.
@MainActor
protocol BudgetGroupExpansionStore: AnyObject {
    func groupExpansion(budgetID: String) -> BudgetGroupExpansion
    func setGroupExpansion(_ expansion: BudgetGroupExpansion, budgetID: String)
}

extension BudgetGroupExpansionStore {
    /// Applies a user toggle against the month's full group list.
    func recordGroupExpansion(
        _ isExpanded: Bool,
        groupID: String,
        budgetID: String,
        groups: [BudgetMonthCategoryGroup]
    ) {
        var expansion = groupExpansion(budgetID: budgetID)
        expansion.record(
            isExpanded: isExpanded,
            groupID: groupID,
            liveGroupIDs: Set(groups.map(\.id))
        )
        setGroupExpansion(expansion, budgetID: budgetID)
    }
}
