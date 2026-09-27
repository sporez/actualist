import Foundation

enum BudgetHoldCommand: Equatable, Sendable {
    case hold(amount: Int)
    case reset
}

/// Exact local-budget revision captured with a hold review. The message count
/// catches an older inserted CRDT message that would not change the maximum
/// timestamp.
struct BudgetHoldReviewRevision: Equatable, Sendable {
    let month: String
    let modeIdentity: BudgetModeIdentity
    let messageCount: Int
    let maxMessageTimestamp: String?
}

struct BudgetHoldReview: Equatable, Sendable {
    let month: String
    let modeIdentity: BudgetModeIdentity
    let currency: BudgetCurrency
    let toBudget: Int
    /// Actual's effective `buffered-selected`: manual when nonzero, otherwise automatic.
    let heldAmount: Int
    /// Stored `zero_budget_months.buffered`, kept separate so reset can reveal an automatic hold.
    let manualHeldAmount: Int
    /// Income activity inferred from current-month income carryover rows.
    let automaticHeldAmount: Int
    let revision: BudgetHoldReviewRevision?

    var isAutomaticHold: Bool {
        manualHeldAmount == 0 && automaticHeldAmount != 0
    }

    init(
        month: String,
        modeIdentity: BudgetModeIdentity,
        currency: BudgetCurrency,
        toBudget: Int,
        heldAmount: Int,
        manualHeldAmount: Int? = nil,
        automaticHeldAmount: Int = 0,
        revision: BudgetHoldReviewRevision? = nil
    ) {
        self.month = month
        self.modeIdentity = modeIdentity
        self.currency = currency
        self.toBudget = toBudget
        self.heldAmount = heldAmount
        self.manualHeldAmount = manualHeldAmount ?? heldAmount
        self.automaticHeldAmount = automaticHeldAmount
        self.revision = revision
    }
}
