import Foundation

/// Exact local-budget identity captured while a template preview reads SQLite.
/// The CRDT count catches older remote inserts that a max timestamp cannot see.
struct BudgetTemplateReviewRevision: Equatable, Sendable {
    let month: String
    let modeIdentity: BudgetModeIdentity
    let messageCount: Int
    let maxMessageTimestamp: String?
}

/// Editor / category dry-run: demand with skip-available-clamp.
struct BudgetTemplateCategoryDryRun: Equatable, Sendable {
    var budgeted: Int
    var perTemplate: [Int]
}

struct BudgetTemplateCategoryMetric: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case available
        case balance
        case received

        var title: String {
            switch self {
            case .available: "Available"
            case .balance: "Balance"
            case .received: "Received"
            }
        }
    }

    var kind: Kind
    var before: Int
    var after: Int

    var title: String { kind.title }
}

/// Apply confirmation preview: clamped like the write path. No budget writes.
struct BudgetTemplateApplyPreview: Equatable, Sendable {
    var modeIdentity: BudgetModeIdentity? = nil
    var assigned: Int
    var leftover: Int
    var isTrackingBudget: Bool
    var currency: BudgetCurrency
    var categories: [Category]
    /// Positive assignment deltas released by this exact apply.
    var released: Int = 0
    /// The demand captured immediately before the apply clamp in the engine.
    var evaluatedDemand: Int = 0
    /// Net new target amount after existing assignments in this apply's
    /// scope are reused. This intentionally does not subtract To Budget.
    var fundingRequired: Int = 0
    /// Positive demand lost at the engine's actual available-funds clamp.
    var stillNeeded: Int = 0
    /// Envelope uses these as To Budget; tracking uses them as Total Saved.
    var availableBefore: Int = 0
    var availableAfter: Int = 0
    /// True when the apply has goal metadata work even though it may move no money.
    var hasNonMoneyUpdates: Bool = false
    /// Whether the selected command found a template it can evaluate, even
    /// when no assignment would change.
    var hasEligibleTemplates: Bool = false
    /// The exact SQLite revision used to calculate this preview.
    var reviewRevision: BudgetTemplateReviewRevision? = nil

    struct Category: Equatable, Sendable {
        var categoryID: String
        var name: String
        var current: Int
        var proposed: Int
        var perTemplate: [Int]
        var drafts: [BudgetTemplateDraft]
        /// Demand captured by the same engine pass as `proposed`.
        var evaluatedDemand: Int = 0
        /// Positive evaluated demand not met by `proposed`.
        var shortfall: Int = 0
        /// Assignment metadata for a goal-only write or orphan-goal cleanup.
        var isGoalOnlyUpdate: Bool = false
        var goalBefore: Int? = nil
        var goalAfter: Int? = nil
        /// Follows BudgetModePresentation: Available for envelope, Balance
        /// for tracking expenses, and Received for tracking income.
        var metric: BudgetTemplateCategoryMetric

    }
}

/// One mode's result in a paired preview. Validation is isolated per mode so
/// an unsupported Fill Empty definition does not discard a valid Overwrite.
enum BudgetTemplatePreviewOutcome: Equatable, Sendable {
    case ready(BudgetTemplateApplyPreview)
    case failed(String)
}

/// Fill Empty and Overwrite calculated from one `BudgetDatabase.queue.read`
/// snapshot. The two outcomes are intentionally independent.
struct BudgetTemplateApplyPreviewPair: Equatable, Sendable {
    var fillEmpty: BudgetTemplatePreviewOutcome
    var overwrite: BudgetTemplatePreviewOutcome
}
