/// The actions that can be offered or accepted for a budget-money edit.
///
/// This policy is deliberately about capability only. It does not calculate
/// amounts, choose a month, or replace the database transaction's mode check.
enum BudgetActionEligibility {
    enum Action: Equatable, Sendable {
        case directAssignment(isIncome: Bool)
        case moveMoney
        case coverOverspending
        case holdForNextMonth
        case carryover(isIncome: Bool)
        case template
    }

    /// Returns whether an action is valid for the budget table currently in use.
    /// Envelope behavior remains permissive so existing envelope entry points
    /// retain their established capability while tracking rolls out separately.
    static func allows(_ action: Action, in table: BudgetTable) -> Bool {
        guard table == .tracking else {
            return true
        }

        switch action {
        case .directAssignment, .template:
            return true
        case .moveMoney, .coverOverspending, .holdForNextMonth:
            return false
        case .carryover(let isIncome):
            return !isIncome
        }
    }
}
